package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

type fakeFleet struct {
	pendingDisk                     bool
	instance                        ec2Host
	launched, terminated, published int
	selected                        string
	lostReply                       bool
}

func (f *fakeFleet) seed(context.Context) (string, error) { return f.selected, nil }
func (f *fakeFleet) launch(_ context.Context, l *lease) (ec2Host, error) {
	f.launched++
	f.instance = ec2Host{"i-1", "vol-2", "running"}
	if f.lostReply {
		return ec2Host{}, &temporaryStatusError{fmt.Errorf("launch reply lost")}
	}
	return f.instance, nil
}
func (f *fakeFleet) host(context.Context, *lease) (ec2Host, error) { return f.instance, nil }
func (f *fakeFleet) terminate(context.Context, string) error {
	f.terminated++
	f.instance.state = "shutting-down"
	return nil
}
func (f *fakeFleet) disksRetiring(context.Context, *lease) (bool, error) { return !f.pendingDisk, nil }
func (f *fakeFleet) publish(context.Context, *lease) error               { f.published++; return nil }

func exampleEC2() ec2Config {
	return ec2Config{Repository: testConfig.Repository, Account: "111111111111", Region: "eu-central-1", Image: "ami-0123456789abcdef0", Subnet: "subnet-0123456789abcdef0", Group: "sg-0123456789abcdef0", Endpoint: "https://runner.example.test", Workflow: ".github/workflows/ci.yml", Job: "build"}
}

func TestEC2ScopesOneLinuxRoute(t *testing.T) {
	cfg := exampleEC2()
	raw, _ := json.Marshal(cfg)
	mac := testConfig
	mac.Platform = "macos"
	mac.DeviceID = testDevice
	linux := testConfig
	linux.DeviceID = testDevice
	configs := []config{mac, linux}
	if err := configureEC2(configs, string(raw)); err != nil || configs[0].EC2.Repository != "" || configs[1].EC2 != cfg {
		t.Fatal(configs, err)
	}
	for _, mutate := range []func(*ec2Config){func(c *ec2Config) { c.Repository = "other/repo" }, func(c *ec2Config) { c.Endpoint = "http://host" }, func(c *ec2Config) { c.Endpoint = "https://user:pass@host" }, func(c *ec2Config) { c.Workflow = "../ci.yml" }} {
		bad := cfg
		mutate(&bad)
		b, _ := json.Marshal(bad)
		if configureEC2(configs, string(b)) == nil {
			t.Fatalf("accepted %+v", bad)
		}
	}
}

func TestEC2Lifecycle(t *testing.T) {
	c, w, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	checkJournalOmitsCredential(t, c, store)
	f := &fakeFleet{selected: "snap-1"}
	c.fleet = f
	c.ec2Auth = []byte("test")
	c.ec2Owner = c.state.Owner
	c.seedAllowed = func(_ context.Context, id int64) (bool, error) { return id == 23, nil }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	if l.EC2.Seed != "snap-1" || w.dispatched != 0 || w.runner != nil || f.launched != 1 {
		t.Fatal(l, w.events)
	}
	loop := newCoordinatorLoop(t.Context(), c)
	done := make(chan struct{})
	go func() { defer close(done); _ = loop.run() }()
	t.Cleanup(func() { <-done })
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/ec2/{runner}/{op}", loop.ec2Handler)
	name := l.Name
	token := bootstrapToken(c.ec2Auth, c.ec2Owner, name)
	request := func(op, key string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/v1/ec2/"+name+"/"+op, nil)
		req.Header.Set("Authorization", "Bearer "+key)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec
	}
	if request("register", "wrong").Code != 403 {
		t.Fatal("accepted invalid credential")
	}
	first := request("register", token)
	if first.Code != 200 || first.Body.String() != "private-jit" || request("register", token).Code != 410 {
		t.Fatal("registration was not single-use")
	}
	if request("quiesced", token).Code != 202 || f.published != 0 {
		t.Fatal("published before GitHub completion")
	}
	job := &scaleset.JobCompleted{RunnerName: name, RunnerID: w.runner.ID, Result: "succeeded", JobMessageBase: scaleset.JobMessageBase{OwnerName: "example", RepositoryName: "application", JobDisplayName: "build", EventName: "push", WorkflowRunID: 23}}
	if err := loop.HandleJobCompleted(t.Context(), job); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if request("quiesced", token).Code != 204 {
			t.Fatal("failed to acknowledge unmount")
		}
	}
	if f.published != 1 {
		t.Fatal("duplicate or missing snapshot", f.published)
	}
	f.instance.state = "shutting-down"
	if _, err := loop.HandleDesiredRunnerCount(t.Context(), 2); err != nil || f.launched != 1 || !c.fallbackFull() {
		t.Fatal("released capacity during termination", err)
	}
	f.instance.state = "terminated"
	f.pendingDisk = true
	if _, err := loop.HandleDesiredRunnerCount(t.Context(), 2); err != nil || !c.fallbackFull() || f.launched != 1 {
		t.Fatal("released slot before disk cleanup", err)
	}
	f.pendingDisk = false
	if _, err := loop.HandleDesiredRunnerCount(t.Context(), 0); err != nil || len(c.state.Leases) != 0 || w.runner != nil || f.launched != 1 {
		t.Fatal("terminal cleanup", err)
	}
	for _, event := range w.events {
		if strings.Contains(event, "secret") {
			t.Fatal("unexpected hosted secret", event)
		}
	}
}

func TestEC2RecoversLostLaunchResponseFromJournal(t *testing.T) {
	c, _, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	f := &fakeFleet{lostReply: true}
	c.fleet = f
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	state, err := store.read()
	if err != nil {
		t.Fatal(err)
	}
	l := singleLease(state)
	if l.EC2 == nil || l.EC2.Instance != "" || !l.DispatchIntent {
		t.Fatal("missing durable launch intent", l)
	}
	c.state = state
	a := c.assigned(l.Name)
	if _, err = a.reconcile(t.Context(), true); err != nil || a.lease.EC2.Instance != "i-1" || f.terminated != 1 || f.launched != 1 {
		t.Fatal("ambiguous launch recovery", err)
	}
}

func TestEC2PromotesOnlySelectedJob(t *testing.T) {
	for _, v := range []struct {
		event, name, owner string
		success            bool
		id                 int
	}{{"pull_request", "build", "example", true, 7}, {"push", "lint", "example", true, 7}, {"push", "build", "other", true, 7}, {"push", "build", "example", false, 7}, {"push", "build", "example", true, 8}} {
		c, _, _ := newFixture(t)
		c.state.Config.EC2 = exampleEC2()
		l := &lease{Name: fixtureRunner, Created: time.Now(), RunnerID: 7, DispatchIntent: true, EC2: &ec2Lease{Issuing: true}}
		c.state.Leases = map[string]*lease{l.Name: l}
		err := c.recordEC2Job(&scaleset.JobCompleted{RunnerName: l.Name, RunnerID: v.id, JobMessageBase: scaleset.JobMessageBase{EventName: v.event, JobDisplayName: v.name, WorkflowRunID: 14, OwnerName: v.owner, RepositoryName: "application"}}, v.success)
		if err != nil || c.state.Leases[l.Name].EC2.ProducerRun != 0 {
			t.Fatal(v, err)
		}
	}
}

func TestEC2VerifiesSeedOrigin(t *testing.T) {
	c := exampleEC2()
	for _, v := range []struct {
		event, branch, sha, repo, path string
		tag, want                      bool
	}{
		{"push", "main", "abc", c.Repository, c.Workflow, false, true},
		{"push", "main", "abc", c.Repository, c.Workflow, true, false},
		{"push", "main", "old", c.Repository, c.Workflow, false, false},
		{"pull_request_target", "main", "abc", c.Repository, c.Workflow, false, false},
		{"push", "main", "abc", "fork/repo", c.Workflow, false, false},
		{"push", "feature", "abc", c.Repository, c.Workflow, false, false},
		{"push", "main", "abc", c.Repository, ".github/workflows/other.yml", false, false},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch strings.TrimPrefix(r.URL.Path, "/repos/"+c.Repository) {
			case "":
				fmt.Fprint(w, `{"default_branch":"main"}`)
			case "/actions/runs/23":
				fmt.Fprintf(w, `{"id":23,"event":%q,"head_branch":%q,"head_sha":%q,"head_repository":{"full_name":%q},"path":%q}`, v.event, v.branch, v.sha, v.repo, v.path)
			case "/git/ref/heads/main":
				fmt.Fprint(w, `{"object":{"sha":"abc"}}`)
			case "/git/ref/tags/main":
				if !v.tag {
					http.NotFound(w, r)
				} else {
					fmt.Fprint(w, "{}")
				}
			default:
				t.Errorf("unexpected GitHub lookup %s", r.URL.Path)
			}
		}))
		g := githubAPI{base: srv.URL, client: srv.Client()}
		got, err := g.trustedSeed(t.Context(), c, 23)
		srv.Close()
		if err != nil || got != v.want {
			t.Fatal(v, got, err)
		}
	}
}

func TestEC2LaunchIsPrivateAndReplayable(t *testing.T) {
	f := awsFleet{cfg: exampleEC2(), owner: "owner", key: []byte("secret")}
	for _, seed := range []string{"", "snap-1"} {
		l := &lease{Name: fixtureRunner, EC2: &ec2Lease{Seed: seed}}
		in := f.launchInput(l)
		b := in.BlockDeviceMappings[0]
		if in.IamInstanceProfile != nil || in.InstanceType != types.InstanceTypeM9gXlarge || in.InstanceInitiatedShutdownBehavior != types.ShutdownBehaviorTerminate || aws.ToString(in.ClientToken) != l.Name || !reflect.DeepEqual(in, f.launchInput(l)) {
			t.Fatal("unsafe or non-repeatable launch")
		}
		if aws.ToString(b.DeviceName) != "/dev/sdf" || aws.ToString(b.Ebs.SnapshotId) != seed || !aws.ToBool(b.Ebs.DeleteOnTermination) || !aws.ToBool(b.Ebs.Encrypted) {
			t.Fatal("incorrect cache disk")
		}
		data, err := base64.StdEncoding.DecodeString(*in.UserData)
		if err != nil || !strings.Contains(string(data), bootstrapToken(f.key, f.owner, l.Name)) || strings.Contains(string(data), "private-jit") {
			t.Fatal("unexpected bootstrap envelope")
		}
	}
}

func TestEC2BootFailureHoldsSlotAcrossRestart(t *testing.T) {
	c, _, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	f := &fakeFleet{}
	c.fleet = f
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	f.instance.state = "terminated"
	for range 2 {
		s, err := store.read()
		if err != nil {
			t.Fatal(err)
		}
		c.state = s
		if _, err = c.HandleDesiredRunnerCount(t.Context(), 1); err == nil || !strings.Contains(err.Error(), "--recover") || len(c.state.Leases) != 1 || f.launched != 1 {
			t.Fatal("unattended relaunch after failed boot", err)
		}
	}
	a := c.assigned(singleLease(c.state).Name)
	if done, err := a.reconcile(t.Context(), true); err != nil || !done || len(c.state.Leases) != 0 {
		t.Fatal("explicit recovery", err)
	}
}
