package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/actions/scaleset"
)

type ec2Config struct {
	Repository string `json:"repository"`
	Region     string `json:"region"`
	Account    string `json:"account"`
	Image      string `json:"image"`
	Subnet     string `json:"subnet"`
	Group      string `json:"security_group"`
	Endpoint   string `json:"endpoint"`
	Workflow   string `json:"seed_workflow"`
	Job        string `json:"seed_job"`
}

func configureEC2(configs []config, raw string) error {
	if raw == "" {
		return nil
	}
	var cfg ec2Config
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return err
	}
	if dec.Decode(new(any)) != io.EOF {
		return errors.New("unexpected trailing EC2 configuration")
	}
	u, err := url.Parse(cfg.Endpoint)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || u.String() != "https://"+u.Host {
		return errors.New("EC2 endpoint must be an HTTPS origin")
	}
	if !regexp.MustCompile(`^[A-Za-z0-9.-]+(:[0-9]+)?$`).MatchString(u.Host) || strings.TrimSpace(cfg.Job) == "" || len(cfg.Job) > 128 || strings.ContainsAny(cfg.Job, "*?\\\r\n") {
		return errors.New("invalid EC2 callback host or seed job name")
	}
	fields := []struct{ name, value, pattern string }{
		{"region", cfg.Region, "^[a-z0-9-]+$"},
		{"account", cfg.Account, "^[0-9]{12}$"},
		{"image", cfg.Image, "^ami-[a-f0-9]{17}$"},
		{"subnet", cfg.Subnet, "^subnet-[a-f0-9]{17}$"},
		{"security_group", cfg.Group, "^sg-[a-f0-9]{17}$"},
		{"seed_workflow", cfg.Workflow, `^\.github/workflows/[A-Za-z0-9_-]+\.ya?ml$`},
	}
	for _, f := range fields {
		if ok, _ := regexp.MatchString(f.pattern, f.value); !ok {
			return fmt.Errorf("invalid EC2 configuration field %q", f.name)
		}
	}
	cfg.Repository = strings.ToLower(cfg.Repository)
	for i, c := range configs {
		if c.Repository == cfg.Repository && c.platform() == "linux" && !c.LocalOnly && c.DeviceID != "" {
			configs[i].EC2 = cfg
			return nil
		}
	}
	return errors.New("EC2 requires a configured Mac-connected Linux repository with hosted fallback")
}

type ec2Lease struct {
	KeyID             string `json:"key_id"`
	Seed              string `json:"seed,omitempty"`
	Instance          string `json:"instance,omitempty"`
	Volume            string `json:"volume,omitempty"`
	Issuing           bool   `json:"issuing,omitempty"`
	Completed         bool   `json:"completed,omitempty"`
	ProducerRun       int64  `json:"producer_run,omitempty"`
	SnapshotAttempted bool   `json:"snapshot_attempted,omitempty"`
}

type ec2Host struct{ id, volume, state string }
type ec2Fleet interface {
	seed(context.Context) (string, error)
	launch(context.Context, *lease) (ec2Host, error)
	host(context.Context, *lease) (ec2Host, error)
	terminate(context.Context, string) error
	disksRetiring(context.Context, *lease) (bool, error)
	publish(context.Context, *lease) error
}

func bootstrapToken(key []byte, owner, name string) string {
	m := hmac.New(sha256.New, key)
	fmt.Fprintf(m, "yieldd-ec2-v1/%s/%s", owner, name)
	return hex.EncodeToString(m.Sum(nil))
}

func ec2KeyID(key []byte) string {
	digest := sha256.Sum256(key)
	return hex.EncodeToString(digest[:])
}

func ec2Key() ([]byte, error) {
	b, err := hex.DecodeString(os.Getenv("YIELDD_EC2_BOOTSTRAP_KEY"))
	if err != nil || len(b) != 32 {
		return nil, errors.New("YIELDD_EC2_BOOTSTRAP_KEY must contain 32 hex-encoded random bytes")
	}
	return b, nil
}

func (a *assignment) provisionEC2(ctx context.Context) error {
	seed, err := a.fleet.seed(ctx)
	if err != nil {
		return err
	}
	next := *a.lease
	next.DispatchIntent = true
	next.EC2 = &ec2Lease{Seed: seed, KeyID: ec2KeyID(a.ec2Auth)}
	if err := a.replace(&next); err != nil {
		return err
	}
	return a.launchEC2(ctx)
}

func (a *assignment) launchEC2(ctx context.Context) error {
	host, err := a.fleet.launch(ctx, a.lease)
	if err != nil {
		return err
	}
	if host.id == "" {
		return errors.New("EC2 launch returned no instance ID")
	}
	next := *a.lease.EC2
	next.Instance, next.Volume = host.id, host.volume
	a.logger.Info("EC2 runner launched", "runner", a.lease.Name, "instance", host.id, "seed", next.Seed)
	return a.saveEC2(next)
}

func (a *assignment) saveEC2(e ec2Lease) error {
	next := *a.lease
	next.EC2 = &e
	return a.replace(&next)
}

func (a *assignment) reconcileEC2(ctx context.Context, recoverOnly bool) (bool, error) {
	l := a.lease
	e := l.EC2
	h, err := a.fleet.host(ctx, l)
	if err != nil {
		return false, err
	}
	age := time.Since(l.Created)
	if h.id == "" && e.Instance == "" && !recoverOnly && age < 5*time.Minute {
		// EC2 deduplicates the exact launch request, including after a lost reply.
		return false, a.launchEC2(ctx)
	}
	// Allow EC2 discovery to converge after an ambiguous launch.
	if h.id == "" && age < 10*time.Minute {
		return false, nil
	}
	if h.id != "" && (e.Instance == "" || (e.Volume == "" && h.volume != "")) {
		next := *e
		next.Instance = h.id
		next.Volume = h.volume
		if err := a.saveEC2(next); err != nil {
			return false, err
		}
	}
	switch h.state {
	case "":
		if h.id != "" {
			return false, errors.New("EC2 omitted instance state")
		}
		fallthrough
	case "terminated":
		retiring, err := a.fleet.disksRetiring(ctx, l)
		if err != nil || !retiring {
			return false, err
		}
		if !recoverOnly && !e.Completed {
			// Preserve the reservation across automatic service restarts. A bad
			// image must not repeatedly launch for the same queued demand.
			return false, fmt.Errorf("EC2 runner ended without a job completion event; inspect the instance and use --recover %s", a.recoveryTarget())
		}
		if err := a.beginCleanup(""); err != nil {
			return false, err
		}
		return a.finishCleanup(ctx, recoverOnly)
	case "shutting-down":
		return false, nil
	case "stopped", "stopping":
		recoverOnly = true
	}
	if recoverOnly || age > 6*time.Hour || (l.RunnerID == 0 && age > 10*time.Minute) {
		return false, a.fleet.terminate(ctx, h.id)
	}
	return false, nil
}

func (c *coordinator) recordEC2Job(job *scaleset.JobCompleted, success bool) error {
	a := c.assigned(job.RunnerName)
	if a.lease == nil || a.lease.EC2 == nil || a.lease.RunnerID <= 0 || a.lease.RunnerID != job.RunnerID || a.lease.EC2.Completed {
		return nil
	}
	e := *a.lease.EC2
	e.Completed = true
	if success && job.EventName == "push" && job.JobDisplayName == c.state.Config.EC2.Job && strings.EqualFold(job.OwnerName+"/"+job.RepositoryName, c.state.Config.Repository) {
		e.ProducerRun = job.WorkflowRunID
	}
	return a.saveEC2(e)
}

func (s *coordinatorLoop) ec2Handler(w http.ResponseWriter, r *http.Request) {
	name, op := r.PathValue("runner"), r.PathValue("op")
	c := s.worker
	if !runnerNamePattern.MatchString(name) || (op != "register" && op != "quiesced") || !hmac.Equal([]byte(r.Header.Get("Authorization")), []byte("Bearer "+bootstrapToken(c.ec2Auth, c.ec2Owner, name))) {
		http.Error(w, "forbidden", 403)
		return
	}
	var jit string
	status := http.StatusGone
	err := s.invoke(r.Context(), func(ctx context.Context) error {
		a := c.assigned(name)
		l := a.lease
		if l == nil || l.CleanupIntent || l.EC2 == nil {
			return nil
		}
		e := *l.EC2
		if e.Instance == "" || (op == "quiesced" && e.ProducerRun > 0 && e.Volume == "") {
			h, err := a.fleet.host(ctx, l)
			if err != nil {
				return err
			}
			if h.id == "" || h.volume == "" {
				status = http.StatusServiceUnavailable
				return nil
			}
			e.Instance, e.Volume = h.id, h.volume
			if err := a.saveEC2(e); err != nil {
				return err
			}
		}
		if op == "register" {
			if e.Issuing || time.Since(l.Created) > 5*time.Minute {
				return nil
			}
			e.Issuing = true
			if err := a.saveEC2(e); err != nil {
				return err
			}
			g, err := a.generateRegistration(ctx)
			if err != nil {
				return err
			}
			next := *a.lease
			next.RunnerID = g.Runner.ID
			if err := a.replace(&next); err != nil {
				return err
			}
			jit = g.EncodedJITConfig
			status = 200
			return nil
		}
		if l.RunnerID == 0 {
			return nil
		}
		if !e.Completed {
			status = http.StatusAccepted
			return nil
		}
		status = http.StatusNoContent
		if e.ProducerRun == 0 || e.SnapshotAttempted || e.Volume == "" {
			return nil
		}
		allowed, err := c.seedAllowed(ctx, e.ProducerRun)
		if err != nil || !allowed {
			return err
		}
		e.SnapshotAttempted = true
		if err := a.saveEC2(e); err != nil {
			return err
		}
		return a.fleet.publish(ctx, a.lease)
	})
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		c.logger.Warn("EC2 bootstrap request failed", "operation", op, "error", err)
		http.Error(w, "bootstrap unavailable", 503)
		return
	}
	w.WriteHeader(status)
	if status == 200 {
		_, _ = io.WriteString(w, jit)
	}
}

func (g *githubAPI) trustedSeed(ctx context.Context, c ec2Config, id int64) (bool, error) {
	base := "/repos/" + c.Repository
	var repo struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := g.request(ctx, "GET", base, nil, &repo); err != nil {
		return false, err
	}
	var run struct {
		ID          int64
		Path, Event string
		Branch      string `json:"head_branch"`
		SHA         string `json:"head_sha"`
		Head        struct {
			Name string `json:"full_name"`
		} `json:"head_repository"`
	}
	if err := g.request(ctx, "GET", fmt.Sprintf("%s/actions/runs/%d", base, id), nil, &run); err != nil {
		return false, err
	}
	if run.ID != id || run.Path != c.Workflow || run.Event != "push" || !strings.EqualFold(run.Head.Name, c.Repository) || repo.DefaultBranch == "" || run.Branch != repo.DefaultBranch || run.SHA == "" {
		return false, nil
	}
	var ref struct{ Object struct{ SHA string } }
	if err := g.request(ctx, "GET", base+"/git/ref/heads/"+url.PathEscape(repo.DefaultBranch), nil, &ref); err != nil {
		return false, err
	}
	if ref.Object.SHA != run.SHA {
		return false, nil
	}
	// The run API represents branch and tag pushes with the same short ref.
	err := g.request(ctx, "GET", base+"/git/ref/tags/"+url.PathEscape(repo.DefaultBranch), nil, &ref)
	if hasHTTPStatus(err, 404) {
		return true, nil
	}
	return false, err
}
