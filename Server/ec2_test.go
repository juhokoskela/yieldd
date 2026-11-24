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
	seedCalls                       int
	seedErr                         error
	lostReply                       bool
}

func (f *fakeFleet) seed(context.Context) (string, error) {
	f.seedCalls++
	return f.selected, f.seedErr
}
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

func TestEC2RouteIgnoresWorkflowFallback(t *testing.T) {
	saved := testConfig
	saved.EC2 = exampleEC2()
	changed := saved
	changed.Fallback = `"another-runner"`
	changed.Infrastructure = "example/other-infrastructure"
	if !saved.sameRoute(changed) {
		t.Fatal("workflow fallback settings changed the EC2 route")
	}
	changed.EC2.Image = "ami-00000000000000001"
	if saved.sameRoute(changed) {
		t.Fatal("accepted a different AMI")
	}
	if saved.sameRoute(testConfig) || testConfig.sameRoute(saved) {
		t.Fatal("accepted switching between EC2 and workflow routes")
	}
	changed.EC2 = ec2Config{}
	if testConfig.sameRoute(changed) {
		t.Fatal("accepted a different fallback workflow route")
	}
}

func TestEC2Lifecycle(t *testing.T) {
	c, w, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	checkJournalOmitsCredential(t, c, store)
	f := &fakeFleet{selected: "snap-1", lostReply: true}
	c.fleet = f
	c.ec2Auth = []byte("test")
	c.ec2Owner = c.state.Owner
	c.seedAllowed = func(_ context.Context, id int64) (bool, error) { return id == 23, nil }
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 2); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	if l.EC2.Instance != "" || l.EC2.Seed != "snap-1" || w.dispatched != 0 || w.runner != nil || f.launched != 1 {
		t.Fatal(l, w.events)
	}
	l.Created = time.Now().Add(-6 * time.Minute) // A retried launch may boot after the five-minute replay window.
	c.verificationRetryAt = time.Time{}          // Allow the first reconciliation after the lost launch reply.
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
	offer := &lease{Local: &localLease{Phase: localOffered, Expires: time.Now().Add(offerLifetime)}}
	if err := loop.invoke(t.Context(), func(context.Context) error { c.state.Leases["offered"] = offer; return nil }); err != nil {
		t.Fatal(err)
	}
	if got := request("register", token).Code; got != http.StatusServiceUnavailable || l.EC2.Issuing || w.runner != nil {
		t.Fatal("registration consumed a live Mac offer", got)
	}
	if err := loop.invoke(t.Context(), func(context.Context) error { delete(c.state.Leases, "offered"); return nil }); err != nil {
		t.Fatal(err)
	}
	f.instance.volume = ""
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
	if got := request("quiesced", token).Code; got != http.StatusServiceUnavailable || f.published != 0 {
		t.Fatal("published without discovering the cache volume", got)
	}
	f.instance.volume = "vol-2"
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

func TestEC2RecoveryWithoutBootstrapKey(t *testing.T) {
	c, world, store := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	fleet := &fakeFleet{}
	c.fleet = fleet
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.FormValue("Action") != "GetCallerIdentity" {
			t.Error("unexpected AWS request", r.FormValue("Action"))
		}
		fmt.Fprint(w, "<GetCallerIdentityResponse><GetCallerIdentityResult><Account>111111111111</Account></GetCallerIdentityResult></GetCallerIdentityResponse>")
	}))
	defer srv.Close()
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_CONFIG_FILE", "/dev/null")
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", "/dev/null")
	t.Setenv("AWS_ACCESS_KEY_ID", "local")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "local")
	t.Setenv("AWS_ENDPOINT_URL_STS", srv.URL)
	t.Setenv("YIELDD_EC2_BOOTSTRAP_KEY", "")
	worker, err := newQueueWorker(c.state, store, "test", 1, true)
	if err != nil {
		t.Fatal(err)
	}
	worker.fleet, worker.runners, worker.bootstrap = fleet, world, world
	worker.device = c.device
	if done, err := worker.reconcile(t.Context(), true); err != nil || done || fleet.terminated != 1 {
		t.Fatal("did not retire the instance", done, err)
	}
	t.Setenv("YIELDD_EC2_BOOTSTRAP_KEY", strings.Repeat("ab", 32))
	if _, err := newQueueWorker(c.state, store, "test", 1, false); err == nil || !strings.Contains(err.Error(), "restore the EC2 bootstrap key") {
		t.Fatal("normal startup accepted a changed key", err)
	}
	fleet.instance.state = "terminated"
	if done, err := worker.reconcile(t.Context(), true); err != nil || !done || len(worker.state.Leases) != 0 {
		t.Fatal("did not release the lease", done, err)
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

func TestEC2AdmissionBacksOffBeforeReserving(t *testing.T) {
	c, w, _ := newFixture(t)
	f := &fakeFleet{seedErr: &temporaryStatusError{fmt.Errorf("occupied")}}
	c.fleet = f
	saves := 0
	save := c.save
	c.save = func(s *state) error { saves++; return save(s) }
	for n := 1; n <= 3; n++ {
		for range 2 {
			if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
				t.Fatal(err)
			}
		}
		if f.seedCalls != n || c.ec2RetryDelay != cleanupRetryDelay<<(n-1) || saves != 0 || len(w.events) != 0 || c.paused != nil {
			t.Fatal("unexpected admission work", f.seedCalls, c.ec2RetryDelay, saves, w.events, c.paused)
		}
		c.ec2RetryAt = time.Now().Add(-time.Second)
	}
	f.seedErr = nil
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil || f.launched != 1 || !c.ec2RetryAt.IsZero() || c.ec2RetryDelay != 0 {
		t.Fatal("failed to admit runner after capacity returned", err)
	}
}

func TestEC2RechecksDemandBeforeLaunchReplay(t *testing.T) {
	for _, demand := range []struct{ listener, github, launches int }{{0, 1, 1}, {1, 0, 1}, {1, 1, 2}} {
		c, w, _ := newFixture(t)
		c.state.Config.EC2 = exampleEC2()
		f := &fakeFleet{lostReply: true}
		c.fleet = f
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		f.instance = ec2Host{}
		c.verificationRetryAt = time.Time{}
		w.assignedJobs = demand.github
		if _, err := c.HandleDesiredRunnerCount(t.Context(), demand.listener); err != nil || f.launched != demand.launches {
			t.Fatal("unexpected launch replay", demand, f.launched, err)
		}
	}
}

func TestEC2ReleasesUnfulfilledOrUnusedRunner(t *testing.T) {
	for _, registered := range []bool{false, true} {
		c, _, _ := newFixture(t)
		c.state.Config.EC2 = exampleEC2()
		f := &fakeFleet{lostReply: !registered}
		c.fleet = f
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
			t.Fatal(err)
		}
		l := singleLease(c.state)
		if registered {
			l.EC2.Issuing, l.RunnerID = true, 7
			f.instance.state = "terminated"
		} else {
			f.instance = ec2Host{}
			l.Created = time.Now().Add(-11 * time.Minute)
			c.verificationRetryAt = time.Time{}
		}
		if _, err := c.HandleDesiredRunnerCount(t.Context(), 0); err != nil || len(c.state.Leases) != 0 || f.launched != 1 {
			t.Fatal("idle runner retained", registered, err)
		}
	}
}

func TestEC2CompletedRunnerRetiresWithoutListenerPoll(t *testing.T) {
	c, _, _ := newFixture(t)
	c.state.Config.EC2 = exampleEC2()
	f := &fakeFleet{}
	c.fleet = f
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	l := singleLease(c.state)
	l.EC2.Issuing, l.EC2.Completed = true, true
	f.instance.state = "terminated"
	cleaned := make(chan struct{})
	save := c.save
	c.save = func(s *state) error {
		err := save(s)
		if err == nil && len(s.Leases) == 0 {
			close(cleaned)
		}
		return err
	}
	ctx, cancel := context.WithCancel(t.Context())
	loop := newCoordinatorLoop(ctx, c)
	done := make(chan error, 1)
	go func() { done <- loop.run() }()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	select {
	case <-cleaned:
		if err := loop.invoke(t.Context(), func(context.Context) error { return nil }); err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * cleanupRetryDelay):
		t.Fatal("completed runner retained until the next listener poll")
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
