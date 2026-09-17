package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net"
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
	var clientListen string
	flag.StringVar(&cfg.Repository, "repository", "", "Application repository (OWNER/REPOSITORY)")
	flag.StringVar(&cfg.Infrastructure, "infrastructure", "", "Infrastructure repository (OWNER/REPOSITORY)")
	flag.StringVar(&cfg.Fallback, "fallback-runner", "", "Hosted target as a JSON label string or array")
	flag.StringVar(&directory, "state-dir", "", "Absolute private state directory")
	flag.BoolVar(&recoverOnly, "recover", false, "Clean up the recorded bootstrap and exit without provisioning")
	flag.StringVar(&cfg.DeviceID, "device-id", "", "UUID of the single connected Linux ARM64 Mac")
	flag.StringVar(&clientListen, "client-listen", "", "Loopback HTTP address behind an HTTPS proxy, for example 127.0.0.1:8787")
	flag.Parse()
	if flag.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if err := cfg.validate(); err != nil {
		return err
	}
	if (cfg.DeviceID == "") != (clientListen == "") && !recoverOnly {
		return errors.New("device-id and client-listen must be supplied together")
	}
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		return errors.New("GH_TOKEN is required on the coordinator; it is never sent to runners")
	}
	var deviceListener net.Listener
	deviceToken := os.Getenv("YIELDD_CLIENT_TOKEN")
	if clientListen != "" && !recoverOnly {
		var err error
		deviceListener, err = listenForDevice(clientListen, deviceToken)
		if err != nil {
			return err
		}
		defer deviceListener.Close()
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
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	worker := &coordinator{state: saved, save: store.save, runners: client, bootstrap: api, logger: slog.Default()}
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
	loopContext, cancelLoop := context.WithCancel(ctx)
	loop := newCoordinatorLoop(loopContext, worker)
	loopDone := make(chan struct{})
	var loopErr error
	go func() {
		defer close(loopDone)
		loopErr = loop.run()
		stop()
	}()
	defer func() { cancelLoop(); <-loopDone }()
	if deviceListener != nil {
		server := &http.Server{Handler: loop.deviceHandler(deviceToken), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 90 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
		serverDone := make(chan struct{})
		go func() {
			defer close(serverDone)
			if err := server.Serve(deviceListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				slog.Error("Device listener stopped", "error", err)
				stop()
			}
		}()
		defer func() {
			if err := drainDeviceHTTP(server); err != nil {
				slog.Warn("Device HTTP drain timed out", "error", err)
			}
			<-serverDone
		}()
		slog.Info("Listening for connected Mac", "address", clientListen, "device", cfg.DeviceID)
	}
	slog.Info("Serving scale set", "repository", cfg.Repository, "scale_set", saved.ScaleSetID, "capacity", 1, "fallback", cfg.Fallback)
	err = messages.Run(ctx, loop)
	cancelLoop()
	<-loopDone
	if loopErr != nil && !onlyCancellation(loopErr) {
		return loopErr
	}
	if err != nil && !onlyCancellation(err) {
		var provisioning *provisioningError
		if errors.As(err, &provisioning) {
			return provisioning
		}
		return &sdkError{"listen for demand", err}
	}
	slog.Info("Stopped; any active bootstrap is recorded for reconciliation on restart")
	return nil
}

func drainDeviceHTTP(server *http.Server) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err := server.Shutdown(ctx)
	if err != nil {
		_ = server.Close()
	}
	return err
}
