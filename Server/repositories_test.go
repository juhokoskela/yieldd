package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRepositoryConfigurationKeepsFallbackSeparateFromInfrastructureCI(t *testing.T) {
	base := testConfig
	base.DeviceID = testDevice
	base.Infrastructure = "juhokoskela/yieldd-infra"
	configs, err := repositoryConfigs(base, "juhokoskela/GlassEQ,juhokoskela/yieldd,juhokoskela/yieldd-infra,juhokoskela/GlassEQServer", "juhokoskela/yieldd-infra", `"macos-26"`)
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
		if _, err := repositoryConfigs(base, test.names, test.local, ""); err == nil {
			t.Fatal("accepted", test)
		}
	}
	base.DeviceID = ""
	if _, err := repositoryConfigs(base, "example/infrastructure", "example/infrastructure", ""); err == nil {
		t.Fatal("local-only without a Mac")
	}
}

func TestRepositoryStateIsIndependentOfConfigurationOrder(t *testing.T) {
	configs, err := repositoryConfigs(testConfig, "example/a,example/b", "", `"macos-26"`)
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
	owners := map[string]string{}
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
		owners[queueDirectory(cfg)] = saved.Owner
	}
	root.Close()
	reordered, err := repositoryConfigs(testConfig, "EXAMPLE/B, example/A", "", `"macos-26"`)
	if err != nil {
		t.Fatal(err)
	}
	root, err = openRepositoryStore(directory, reordered)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	reloaded := map[string]string{}
	seen := map[string]bool{}
	for _, cfg := range reordered {
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
		reloaded[queueDirectory(cfg)] = saved.Owner
	}
	if !reflect.DeepEqual(owners, reloaded) {
		t.Fatal(owners, reloaded)
	}
}

func TestRepositoryStateRejectsLegacyRemovedAndSymlinkedQueues(t *testing.T) {
	for _, kind := range []string{"legacy", "legacy macos", "removed repository", "removed platform", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			directory := filepath.Join(t.TempDir(), "state")
			if err := os.Mkdir(directory, 0o700); err != nil {
				t.Fatal(err)
			}
			configs := []config{testConfig}
			var file string
			switch kind {
			case "legacy":
				file = filepath.Join(directory, "state.json")
			case "legacy macos":
				file = filepath.Join(directory, "macos/state.json")
			case "removed repository":
				file = filepath.Join(directory, "queues/example/removed/linux/state.json")
			case "removed platform":
				file = filepath.Join(directory, "queues/example/application/macos/state.json")
			case "symlink":
				if err := os.Symlink(t.TempDir(), filepath.Join(directory, "queues")); err != nil {
					t.Fatal(err)
				}
			}
			if file != "" {
				if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(file, []byte("retained cleanup state"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if store, err := openRepositoryStore(directory, configs); err == nil {
				store.Close()
				t.Fatal("unsafe layout accepted")
			}
			if file != "" {
				data, err := os.ReadFile(file)
				if err != nil || string(data) != "retained cleanup state" {
					t.Fatal("state modified", err)
				}
			}
		})
	}
}
