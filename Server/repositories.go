package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

func repositoryConfigs(base config, repositories, localOnly, macOSFallback string) ([]config, error) {
	names, err := repositoryList(repositories)
	if err != nil {
		return nil, err
	}
	var local []string
	if localOnly != "" {
		local, err = repositoryList(localOnly)
		if err != nil {
			return nil, err
		}
	}
	for _, name := range local {
		if !slices.Contains(names, name) {
			return nil, errors.New("local-only repositories must also appear in --repositories")
		}
	}
	var configs []config
	for _, name := range names {
		c := base
		c.Repository, c.LocalOnly = name, slices.Contains(local, name)
		platforms := []config{c}
		if macOSFallback != "" {
			mac := c
			mac.Platform, mac.Fallback = "macos", macOSFallback
			platforms = append(platforms, mac)
		}
		for _, queue := range platforms {
			if queue.LocalOnly {
				queue.Fallback = ""
			}
			if err := queue.validate(); err != nil {
				return nil, fmt.Errorf("repository %s: %w", name, err)
			}
			configs = append(configs, queue)
		}
	}
	return configs, nil
}

func repositoryList(value string) ([]string, error) {
	names := strings.Split(value, ",")
	if len(names) > 16 {
		return nil, errors.New("at most 16 repositories are supported")
	}
	seen := map[string]bool{}
	for i, name := range names {
		name = strings.ToLower(strings.TrimSpace(name))
		_, repository, _ := strings.Cut(name, "/")
		if !repositoryPattern.MatchString(name) || repository == "." || repository == ".." {
			return nil, errors.New("repositories must be a comma-separated list of OWNER/REPOSITORY names")
		}
		if seen[name] {
			return nil, fmt.Errorf("duplicate repository %s", name)
		}
		seen[name], names[i] = true, name
	}
	return names, nil
}

func queueDirectory(c config) string {
	return filepath.Join("queues", c.Repository, c.platform())
}

// Lock the whole deployment, including queues without an existing state file.
// Never silently omit an old queue or reinterpret the single-repository layout.
func openRepositoryStore(directory string, configs []config) (_ *stateStore, err error) {
	store, err := openStore(directory)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			store.Close()
		}
	}()
	for _, path := range []string{"state.json", "macos/state.json"} {
		if _, err := store.root.Lstat(path); err == nil {
			return nil, errors.New("single-repository state found; recover it with the previous version before using a new state volume for multiple repositories")
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	if info, err := store.root.Lstat("queues"); err == nil {
		if !info.IsDir() {
			return nil, errors.New("queues must be a directory, not a symlink or file")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		return store, nil
	} else {
		return nil, err
	}
	allowed := map[string]bool{}
	for _, c := range configs {
		allowed[filepath.ToSlash(filepath.Join(queueDirectory(c), "state.json"))] = true
	}
	err = fs.WalkDir(store.root.FS(), "queues", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("queue state cannot contain a symlink: %s", path)
		}
		if !entry.IsDir() && entry.Name() == "state.json" && !allowed[path] {
			return fmt.Errorf("saved queue %s is not configured; restore its repository and platform, finish recovery, then archive its queue directory before removing it", path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return store, nil
}
