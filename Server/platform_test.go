package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

type scaleSetWriteResponse struct {
	*fakeScaleSets
	response *scaleset.RunnerScaleSet
}

func (f *scaleSetWriteResponse) CreateRunnerScaleSet(context.Context, *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	f.created++
	return f.response, nil
}

func (f *scaleSetWriteResponse) UpdateRunnerScaleSet(context.Context, int, *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	f.updated++
	return f.response, nil
}

func TestPlatformUpdateRejectsChangedIdentity(t *testing.T) {
	for _, field := range []string{"nil", "id", "name", "group"} {
		t.Run(field, func(t *testing.T) {
			original := &scaleset.RunnerScaleSet{ID: 1, Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd", Type: "system"}}}
			response := *original
			response.Labels = []scaleset.Label{{Name: "yieldd"}, {Name: "yieldd-linux"}}
			api := &scaleSetWriteResponse{fakeScaleSets: &fakeScaleSets{set: original}, response: &response}
			switch field {
			case "nil":
				api.response = nil
			case "id":
				response.ID++
			case "name":
				response.Name = "yieldd-macos"
			case "group":
				response.RunnerGroupID++
			}
			if _, err := ensurePlatformScaleSet(t.Context(), api, testConfig, 1); err == nil || !strings.Contains(err.Error(), "identity") {
				t.Fatal("expected an identity diagnostic", err)
			}
			if api.created != 0 || api.updated != 1 {
				t.Fatal("unexpected mutation", api.created, api.updated)
			}
		})
	}
}

func TestPlatformUpdateReportsMissingLabels(t *testing.T) {
	original := &scaleset.RunnerScaleSet{ID: 1, Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd", Type: "system"}}}
	response := *original
	response.Labels = []scaleset.Label{{Name: "yieldd-macos", Type: "system"}}
	api := &scaleSetWriteResponse{fakeScaleSets: &fakeScaleSets{set: original}, response: &response}
	_, err := ensurePlatformScaleSet(t.Context(), api, testConfig, 1)
	if err == nil || !strings.Contains(err.Error(), "labels") || !strings.Contains(err.Error(), fmt.Sprint(response.ID)) {
		t.Fatal("expected scale-set ID and label diagnostic", err)
	}
}

func TestPlatformPreservesSavedLinuxSetWhenAliasUpdateIsIgnored(t *testing.T) {
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	original := &scaleset.RunnerScaleSet{ID: 1, Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd", Type: "system"}}}
	api := &scaleSetWriteResponse{fakeScaleSets: &fakeScaleSets{set: original}, response: original}
	id, err := ensurePlatformScaleSet(t.Context(), api, testConfig, 1)
	if err != nil || id != 1 || api.created != 0 || api.updated != 1 {
		t.Fatal("legacy identity was not preserved", id, err, api.created, api.updated)
	}
	for _, field := range []string{"level=WARN", "scale_set=1", "alias=yieldd-linux", "runs-on: yieldd"} {
		if !strings.Contains(logs.String(), field) {
			t.Fatal("missing actionable alias warning", field, logs.String())
		}
	}
}

func TestPlatformAliasCompatibilityRequiresSavedLegacyLabels(t *testing.T) {
	for _, saved := range []bool{false, true} {
		t.Run(fmt.Sprint(saved), func(t *testing.T) {
			original := &scaleset.RunnerScaleSet{ID: 1, Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd"}}}
			savedID := 0
			if saved {
				savedID = 1
				original.Labels = append(original.Labels, scaleset.Label{Name: "unexpected"})
			}
			response := *original
			response.Labels = []scaleset.Label{{Name: "yieldd"}}
			api := &scaleSetWriteResponse{fakeScaleSets: &fakeScaleSets{set: original}, response: &response}
			if _, err := ensurePlatformScaleSet(t.Context(), api, testConfig, savedID); err == nil {
				t.Fatal("compatibility accepted a set without a saved legacy identity")
			}
		})
	}
}

func TestPlatformCreationRequiresAllLabels(t *testing.T) {
	for _, platform := range []string{"", "macos"} {
		t.Run(platform, func(t *testing.T) {
			cfg := testConfig
			cfg.Platform = platform
			response := &scaleset.RunnerScaleSet{ID: 42, Name: cfg.scaleSetName(), RunnerGroupID: 1}
			if platform == "" {
				response.Labels = []scaleset.Label{{Name: "yieldd"}}
			}
			api := &scaleSetWriteResponse{fakeScaleSets: &fakeScaleSets{}, response: response}
			if _, err := ensurePlatformScaleSet(t.Context(), api, cfg, 0); err == nil || !strings.Contains(err.Error(), "labels") {
				t.Fatal("new set accepted incomplete routing labels", err)
			}
			if api.created != 1 || api.updated != 0 {
				t.Fatal("unexpected mutation", api.created, api.updated)
			}
		})
	}
}

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
