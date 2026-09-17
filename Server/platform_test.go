package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

type fakeScaleSets struct {
	set              *scaleset.RunnerScaleSet
	created, updated int
	requestedName    string
}

func (f *fakeScaleSets) GetRunnerScaleSet(_ context.Context, _ int, name string) (*scaleset.RunnerScaleSet, error) {
	f.requestedName = name
	return f.set, nil
}
func (f *fakeScaleSets) GetRunnerScaleSetByID(context.Context, int) (*scaleset.RunnerScaleSet, error) {
	return f.set, nil
}
func (f *fakeScaleSets) CreateRunnerScaleSet(_ context.Context, set *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	f.created++
	set.ID = 42
	f.set = set
	return set, nil
}
func (f *fakeScaleSets) UpdateRunnerScaleSet(_ context.Context, id int, set *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	f.updated++
	set.ID = id
	f.set = set
	return set, nil
}

func TestPlatformLabelsPreserveLinuxIdentity(t *testing.T) {
	linux := &fakeScaleSets{set: &scaleset.RunnerScaleSet{ID: 7, Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd"}}}}
	id, err := ensurePlatformScaleSet(t.Context(), linux, testConfig, 7)
	if err != nil || id != 7 || linux.created != 0 || linux.updated != 1 {
		t.Fatal(id, err, linux)
	}
	if !sameLabels(linux.set.Labels, []scaleset.Label{{Name: "yieldd"}, {Name: "yieldd-linux"}}) {
		t.Fatal(linux.set.Labels)
	}
	if _, err := ensurePlatformScaleSet(t.Context(), linux, testConfig, 7); err != nil || linux.updated != 1 {
		t.Fatal("unnecessary update", err)
	}
	cfg := testConfig
	cfg.Platform = "macos"
	mac := &fakeScaleSets{}
	if id, err := ensurePlatformScaleSet(t.Context(), mac, cfg, 0); err != nil || id != 42 {
		t.Fatal(id, err)
	}
	if mac.requestedName != "yieldd-macos" || len(mac.set.Labels) != 1 || mac.set.Labels[0].Name != "yieldd-macos" {
		t.Fatal(mac)
	}
	if _, err := ensurePlatformScaleSet(t.Context(), linux, cfg, 7); err == nil {
		t.Fatal("Linux scale set reused for macOS")
	}
	if _, err := ensurePlatformScaleSet(t.Context(), &fakeScaleSets{}, cfg, 7); err == nil {
		t.Fatal("missing identity replaced")
	}
}

func TestPlatformFallbackCannotRouteBackToEitherScaleSet(t *testing.T) {
	for _, label := range []string{"yieldd", "yieldd-linux", "yieldd-macos", "YIELDD-MACOS"} {
		cfg := testConfig
		cfg.Fallback = `["self-hosted","GROUP"]`
		cfg.Fallback = strings.ReplaceAll(cfg.Fallback, "GROUP", label)
		if err := cfg.validate(); err == nil {
			t.Fatal("recursive fallback", label)
		}
	}
}

func TestPlatformDeviceRoutingAndRecoveryStayIndependent(t *testing.T) {
	linux, linuxWorld, linuxStore, linuxRequest := localFixture(t)
	mac, macWorld, macStore, macRequest := localFixture(t)
	mac.state.Config.Platform, mac.state.Config.Fallback = "macos", `"macos-26"`
	if err := mac.save(mac.state); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	linuxLoop, macLoop := newCoordinatorLoop(ctx, linux), newCoordinatorLoop(ctx, mac)
	done := make(chan error, 2)
	go func() { done <- linuxLoop.run() }()
	go func() { done <- macLoop.run() }()
	defer func() { cancel(); <-done; <-done }()
	token := strings.Repeat("x", 32)
	mux := http.NewServeMux()
	mux.Handle("/v1/macos/", platformDeviceHandler(macLoop.deviceHandler(token)))
	mux.Handle("/", linuxLoop.deviceHandler(token))
	call := func(path string, request deviceRequest) *httptest.ResponseRecorder {
		t.Helper()
		data, _ := json.Marshal(request)
		req := httptest.NewRequest("POST", path, strings.NewReader(string(data)))
		req = req.WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, req)
		return response
	}
	for _, test := range []struct {
		path, platform string
		request        deviceRequest
	}{
		{"/v1/poll", "linux", linuxRequest}, {"/v1/macos/poll", "macos", macRequest},
	} {
		response := call(test.path, test.request)
		var offer deviceOffer
		if err := json.Unmarshal(response.Body.Bytes(), &offer); err != nil || response.Code != 200 || offer.Platform != test.platform {
			t.Fatal(response, offer, err)
		}
	}
	if response := call("/v1/accept", macRequest); response.Code != 409 {
		t.Fatal("cross-platform acceptance", response.Code)
	}
	if response := call("/v1/macos/accept", macRequest); response.Code != 200 {
		t.Fatal(response.Code, response.Body)
	}
	if response := call("/v1/accept", linuxRequest); response.Code != 200 {
		t.Fatal(response.Code, response.Body)
	}
	if response := call("/v1/macos/complete", linuxRequest); response.Code != 409 {
		t.Fatal("cross-platform cleanup", response.Code)
	}
	if response := call("/v1/macos/complete", macRequest); response.Code != 200 {
		t.Fatal(response.Code, response.Body)
	}
	// Read persisted snapshots rather than the event-loop-owned objects.
	saved, err := macStore.load(mac.state.Config)
	if err != nil || saved.Lease != nil {
		t.Fatal(saved, err)
	}
	saved, err = linuxStore.load(linux.state.Config)
	if err != nil || saved.Lease == nil || saved.Lease.Local.Phase != localIssued {
		t.Fatal(saved, err)
	}
	if linuxWorld.dispatched != 0 || macWorld.dispatched != 0 {
		t.Fatal("local execution dispatched hosted")
	}
}

func TestMacOSOfferExpiryUsesOnlyItsConfiguredFallback(t *testing.T) {
	mac, w, _, _ := localFixture(t)
	mac.state.Config.Platform, mac.state.Config.Fallback = "macos", `["self-hosted","my-mac"]`
	mac.state.Lease.Local.Expires = time.Now().Add(-time.Second)
	if _, err := mac.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	if w.fallback != mac.state.Config.Fallback || w.dispatched != 1 {
		t.Fatal(w.fallback, w.dispatched)
	}
}

func TestExistingLinuxStateNeedsNoConfigurationMigration(t *testing.T) {
	c, _, store := newFixture(t)
	if err := store.save(c.state); err != nil {
		t.Fatal(err)
	}
	saved, err := store.load(testConfig)
	if err != nil || saved.Config.platform() != "linux" || saved.ScaleSetID != c.state.ScaleSetID {
		t.Fatal(saved, err)
	}
	changed := testConfig
	changed.Platform = "macos"
	if _, err := store.load(changed); err == nil {
		t.Fatal("Linux state loaded as macOS")
	}
}
