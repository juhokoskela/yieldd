package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestRepositoryConfigurationKeepsFallbackSeparateFromInfrastructureCI(t *testing.T) {
	base := testConfig
	base.DeviceID = testDevice
	base.Infrastructure = "juhokoskela/yieldd-infra"
	configs, err := repositoryConfigs(base, "juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer", "juhokoskela/yieldd-infra", `"macos-26"`, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(configs) != 8 {
		t.Fatal(configs)
	}
	for _, cfg := range configs {
		if cfg.LocalOnly != (cfg.Repository == base.Infrastructure) {
			t.Fatal(cfg)
		}
		if cfg.LocalOnly {
			if cfg.Fallback != "" {
				t.Fatal("infrastructure CI can dispatch itself", cfg)
			}
		} else if cfg.platform() == "linux" && cfg.Fallback != base.Fallback || cfg.platform() == "macos" && !cfg.LocalOnly && cfg.Fallback != `"macos-26"` {
			t.Fatal("fallback changed", cfg)
		}
	}
	if got := queueDirectory(configs[0]); got != "queues/juhokoskela/glasseq/linux" {
		t.Fatal(got)
	}
	if got := queueDirectory(configs[1]); got != "queues/juhokoskela/glasseq/macos" {
		t.Fatal(got)
	}
}

func TestRepositoryConfigurationRejectsAmbiguousOrUnsafeQueues(t *testing.T) {
	base := testConfig
	base.DeviceID = testDevice
	for _, test := range []struct{ names, local string }{
		{"", ""}, {"example/a,", ""}, {"example/a,EXAMPLE/A", ""},
		{"../a", ""}, {"example/..", ""}, {"example/a/../../b", ""},
		{strings.Repeat("example/a,", 16) + "example/b", ""},
		{"example/a", "example/b"}, {"example/infrastructure", ""},
	} {
		if _, err := repositoryConfigs(base, test.names, test.local, "", ""); err == nil {
			t.Fatal("accepted", test)
		}
	}
	base.DeviceID = ""
	if _, err := repositoryConfigs(base, "example/infrastructure", "example/infrastructure", "", ""); err == nil {
		t.Fatal("local-only without a Mac")
	}
}

func TestRepositoryStateIsIndependentOfConfigurationOrder(t *testing.T) {
	configs, err := repositoryConfigs(testConfig, "example/a,example/b", "", `"macos-26"`, "")
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(t.TempDir(), "state")
	root, err := openRepositoryStore(directory, configs)
	if err != nil {
		t.Fatal(err)
	}
	if other, err := openRepositoryStore(directory, configs); err == nil {
		other.Close()
		t.Fatal("deployment lock not exclusive")
	}
	owners := loadQueueOwners(t, directory, configs)
	root.Close()
	reordered, err := repositoryConfigs(testConfig, "EXAMPLE/B, example/A", "", `"macos-26"`, "")
	if err != nil {
		t.Fatal(err)
	}
	root, err = openRepositoryStore(directory, reordered)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if reloaded := loadQueueOwners(t, directory, reordered); !reflect.DeepEqual(owners, reloaded) {
		t.Fatal(owners, reloaded)
	}
}

func loadQueueOwners(t *testing.T, directory string, configs []config) map[string]string {
	t.Helper()
	owners := map[string]string{}
	seen := map[string]bool{}
	for _, cfg := range configs {
		store, err := openStore(filepath.Join(directory, queueDirectory(cfg)))
		if err != nil {
			t.Fatal(err)
		}
		saved, err := store.load(cfg)
		store.Close()
		if err != nil {
			t.Fatal(err)
		}
		if seen[saved.Owner] {
			t.Fatal("queue owner reused", saved.Owner)
		}
		seen[saved.Owner] = true
		owners[queueDirectory(cfg)] = saved.Owner
	}
	return owners
}

func TestRepositoryNamedStateJSONRestarts(t *testing.T) {
	configs, err := repositoryConfigs(testConfig, "example/state.json", "", `"macos-26"`, "")
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(t.TempDir(), "state")
	var previous map[string]string
	for range 2 {
		root, err := openRepositoryStore(directory, configs)
		if err != nil {
			t.Fatal(err)
		}
		owners := loadQueueOwners(t, directory, configs)
		root.Close()
		if previous != nil && !reflect.DeepEqual(previous, owners) {
			t.Fatal("restart changed identities", previous, owners)
		}
		previous = owners
	}
}

func TestRepositoryStateRejectsLegacyRemovedAndSymlinkedQueues(t *testing.T) {
	for _, test := range []struct {
		name, path string
		symlink    bool
	}{
		{"legacy", "state.json", false},
		{"legacy macos", "macos/state.json", false},
		{"removed repository", "queues/example/removed/linux/state.json", false},
		{"removed platform", "queues/example/application/macos/state.json", false},
		{"symlinked root", "queues", true},
		{"symlinked repository", "queues/example/application", true},
		{"symlinked journal", "queues/example/application/linux/state.json", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "state")
			if err := os.Mkdir(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			configs := []config{testConfig}
			file := filepath.Join(directory, test.path)
			if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
				t.Fatal(err)
			}
			if test.symlink {
				if err := os.Symlink(t.TempDir(), file); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.WriteFile(file, []byte("retained cleanup state"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if store, err := openRepositoryStore(directory, configs); err == nil {
				store.Close()
				t.Fatal("unsafe layout accepted")
			}
			if !test.symlink {
				data, err := os.ReadFile(file)
				if err != nil || string(data) != "retained cleanup state" {
					t.Fatal("state modified", err)
				}
			}
		})
	}
}

func TestRepositoryRoutesKeepProvidersAndInfrastructureSeparate(t *testing.T) {
	base := testConfig
	base.DeviceID = testDevice
	base.Infrastructure = "juhokoskela/yieldd-infra"
	base.Fallback = `"avrea-ubuntu-latest-arm-2-vcpu"`
	routes := `[{"repository":" SPLCompanyOy/LibreChat ","infrastructure":"SPLCompanyOy/yieldd-infra","fallback":"blacksmith-4vcpu-ubuntu-2404-arm"}]`
	configs, err := repositoryConfigs(base,
		"juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer,SPLCompanyOy/LibreChat",
		"juhokoskela/yieldd-infra", `"avrea-macos-26-8-vcpu"`, routes)
	if err != nil {
		t.Fatal(err)
	}
	if len(configs) != 10 {
		t.Fatal(configs)
	}
	directory := t.TempDir()
	for _, cfg := range configs {
		infrastructure, fallback := base.Infrastructure, base.Fallback
		if cfg.Repository == "splcompanyoy/librechat" {
			infrastructure, fallback = "splcompanyoy/yieldd-infra", `"blacksmith-4vcpu-ubuntu-2404-arm"`
		}
		if cfg.platform() == "macos" {
			fallback = `"avrea-macos-26-8-vcpu"`
		}
		if cfg.LocalOnly {
			fallback = ""
		}
		if cfg.Infrastructure != infrastructure || cfg.Fallback != fallback || cfg.DeviceID != testDevice {
			t.Fatal("queue used another repository's route", cfg)
		}
		worker, err := openPlatformCoordinator(t.Context(), cfg, filepath.Join(directory, queueDirectory(cfg)), "offline-token", true, defaultMaxFallbackRunners)
		if err != nil {
			t.Fatal(err)
		}
		api, ok := worker.loop.worker.bootstrap.(*githubAPI)
		if !ok || api.infrastructure != infrastructure || worker.loop.worker.state.Config != cfg {
			t.Error("bootstrap client and journal disagree with the configured route", cfg)
		}
		worker.close(t.Context())
	}
}

func TestRepositoryRouteSupportsLabelArraysWithoutEnablingMacOS(t *testing.T) {
	routes := `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":["self-hosted","disposable","ARM64"]}]`
	configs, err := repositoryConfigs(testConfig, "example/application", "", "", routes)
	if err != nil {
		t.Fatal(err)
	}
	if len(configs) != 1 || configs[0].Infrastructure != "company/bootstrap" || configs[0].Fallback != `["self-hosted","disposable","ARM64"]` {
		t.Fatal(configs)
	}
}

func TestRepositoryRoutesRejectInvalidOrAmbiguousOverrides(t *testing.T) {
	for _, test := range []struct {
		name, routes, local string
	}{
		{"malformed JSON", `[{`, ""},
		{"not an array", `{}`, ""},
		{"null", `null`, ""},
		{"trailing JSON", `[] []`, ""},
		{"unknown field", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":"runner","typo":true}]`, ""},
		{"unknown repository", `[{"repository":"example/other","infrastructure":"company/bootstrap","fallback":"runner"}]`, ""},
		{"missing repository", `[{"infrastructure":"company/bootstrap","fallback":"runner"}]`, ""},
		{"missing infrastructure", `[{"repository":"example/application","fallback":"runner"}]`, ""},
		{"invalid infrastructure", `[{"repository":"example/application","infrastructure":"company/../bootstrap","fallback":"runner"}]`, ""},
		{"self bootstrap", `[{"repository":"example/application","infrastructure":"EXAMPLE/APPLICATION","fallback":"runner"}]`, ""},
		{"missing fallback", `[{"repository":"example/application","infrastructure":"company/bootstrap"}]`, ""},
		{"null fallback", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":null}]`, ""},
		{"empty labels", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":[]}]`, ""},
		{"recursive provider", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":"yieldd"}]`, ""},
		{"duplicate repository", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":"runner"},{"repository":"EXAMPLE/APPLICATION","infrastructure":"company/other","fallback":"other"}]`, ""},
		{"local-only override", `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":"runner"}]`, "example/application"},
	} {
		t.Run(test.name, func(t *testing.T) {
			base := testConfig
			base.DeviceID = testDevice
			if _, err := repositoryConfigs(base, "example/application", test.local, "", test.routes); err == nil {
				t.Fatal("invalid repository route accepted")
			}
		})
	}
}

func TestRepositoryRouteChangeCannotRedirectPersistedCleanup(t *testing.T) {
	old, err := repositoryConfigs(testConfig, "example/application", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	routes := `[{"repository":"example/application","infrastructure":"company/bootstrap","fallback":"runner"}]`
	next, err := repositoryConfigs(testConfig, "example/application", "", "", routes)
	if err != nil {
		t.Fatal(err)
	}
	store, err := openStore(filepath.Join(t.TempDir(), queueDirectory(old[0])))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	saved, err := store.load(old[0])
	if err != nil {
		t.Fatal(err)
	}
	saved.ScaleSetID = 1
	saved.Leases = map[string]*lease{fixtureRunner: {
		Name: fixtureRunner, Created: time.Now().UTC(), RunnerID: 99, RunID: 101, DispatchIntent: true,
	}}
	if err := store.save(saved); err != nil {
		t.Fatal(err)
	}
	if _, err := store.load(next[0]); err == nil || !strings.Contains(err.Error(), "state belongs to a different configuration") {
		t.Fatal("pending cleanup was reinterpreted under a new bootstrap repository", err)
	}
	reloaded, err := store.load(old[0])
	if err != nil || !reflect.DeepEqual(saved, reloaded) {
		t.Fatal("original cleanup identity changed", reloaded, err)
	}
}

func TestActiveQueueComparesDecodedFallbackLabels(t *testing.T) {
	c, _, store := multipleFallbackFixture(t, 1)
	c.state.Config.Fallback = "[\"arm64\", \"runner\"]"
	if _, err := c.HandleDesiredRunnerCount(t.Context(), 1); err != nil {
		t.Fatal(err)
	}
	requested := c.state.Config
	requested.Fallback = "[ \"arm64\",\n \"r\\u0075nner\" ]"
	loaded, err := store.load(requested)
	if err != nil || !reflect.DeepEqual(loaded, c.state) {
		t.Fatal("reformatted labels changed an active queue", loaded, err)
	}
	requested.Fallback = "[\"arm64\",\"other\"]"
	if _, err := store.load(requested); err == nil {
		t.Fatal("active lease accepted a different runner target")
	}
}

func TestEmptyQueueAdoptsRoutingAndKeepsIdentity(t *testing.T) {
	c, _, store, request := localFixture(t)
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatal(err)
	}
	old, err := store.load(c.state.Config)
	if err != nil {
		t.Fatal(err)
	}
	next := c.state.Config
	next.Fallback = `"other-provider"`
	s, err := store.load(next)
	if err != nil {
		t.Fatal(err)
	}
	if s.Owner != old.Owner || s.ScaleSetID != old.ScaleSetID || s.Config != next {
		t.Fatal(s)
	}
	s, err = store.load(next)
	if err != nil || s.Owner != old.Owner {
		t.Fatal(s, err)
	}
	c.state = s
	if err := c.completeDevice(t.Context(), request); err != nil {
		t.Fatalf("old acknowledgement after route change: %v", err)
	}
}
