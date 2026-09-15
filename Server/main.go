package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

func main() {
	if err := run(); err != nil {
		slog.Error("Coordinator stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	var cfg config
	var directory string
	var recoverOnly bool
	flag.StringVar(&cfg.Repository, "repository", "", "Application repository (OWNER/REPOSITORY)")
	flag.StringVar(&cfg.Infrastructure, "infrastructure", "", "Infrastructure repository (OWNER/REPOSITORY)")
	flag.StringVar(&cfg.Fallback, "fallback-runner", "", "Hosted target as a JSON label string or array")
	flag.StringVar(&directory, "state-dir", "", "Absolute private state directory")
	flag.BoolVar(&recoverOnly, "recover", false, "Clean up the recorded bootstrap and exit without provisioning")
	flag.Parse()
	if flag.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if err := cfg.validate(); err != nil {
		return err
	}
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		return errors.New("GH_TOKEN is required on the coordinator; it is never sent to runners")
	}
	store, err := openStore(directory)
	if err != nil {
		return err
	}
	defer store.Close()
	saved, err := store.load(cfg)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	// Retrying a registration POST after a lost response can create an untracked runner.
	client, err := scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
		GitHubConfigURL: "https://github.com/" + cfg.Repository, PersonalAccessToken: token,
		SystemInfo: scaleset.SystemInfo{System: "yieldd", Version: "prototype", Subsystem: "coordinator"},
	}, scaleset.WithRetryMax(0), scaleset.WithTimeout(60*time.Second))
	if err != nil {
		return &sdkError{"initialize client", err}
	}
	api := &githubAPI{base: "https://api.github.com", token: token, infrastructure: cfg.Infrastructure, client: &http.Client{
		Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	worker := &coordinator{lifetime: ctx, state: saved, save: store.save, runners: client, bootstrap: api, now: time.Now, logger: slog.Default()}
	if recoverOnly {
		for {
			done, err := worker.reconcile(ctx, true)
			if err != nil {
				return err
			}
			if done {
				return nil
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
		}
	}
	if saved.ScaleSetID == 0 {
		set, err := client.GetRunnerScaleSet(ctx, 1, "yieldd")
		if err != nil {
			return &sdkError{"find scale set", err}
		}
		if set == nil {
			set, err = client.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{Name: "yieldd", RunnerGroupID: 1, Labels: []scaleset.Label{{Name: "yieldd", Type: "System"}}, RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true}})
			if err != nil {
				return &sdkError{"create scale set", err}
			}
		}
		if set == nil || set.ID <= 0 {
			return errors.New("invalid scale set response")
		}
		saved.ScaleSetID = set.ID
		if err := store.save(saved); err != nil {
			return err
		}
	}
	session, err := client.MessageSessionClient(ctx, saved.ScaleSetID, saved.Owner)
	if err != nil {
		return &sdkError{"open message session", err}
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := session.Close(cleanup); err != nil {
			slog.Error("Close scale set session", "error", &sdkError{"close message session", err})
		}
	}()
	messages, err := listener.New(session, listener.Config{ScaleSetID: saved.ScaleSetID, MaxRunners: 1})
	if err != nil {
		return err
	}
	slog.Info("Serving scale set", "repository", cfg.Repository, "scale_set", saved.ScaleSetID, "capacity", 1, "fallback", cfg.Fallback)
	if err := messages.Run(ctx, worker); err != nil && !errors.Is(err, context.Canceled) {
		var provisioning *provisioningError
		if errors.As(err, &provisioning) {
			return provisioning
		}
		return &sdkError{"listen for demand", err}
	}
	slog.Info("Stopped; any active bootstrap is recorded for reconciliation on restart")
	return nil
}
