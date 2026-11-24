package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		slog.Error("Coordinator stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	var cfg config
	var directory, clientListen, macOSFallback, repositories, localOnly, repositoryRoutes string
	var recoverAll, allowNonLoopbackClientListen bool
	var recoverTarget string
	var maxFallbackRunners int
	flag.StringVar(&repositories, "repositories", "", "Comma-separated application repositories (OWNER/REPOSITORY)")
	flag.StringVar(&localOnly, "local-only-repositories", "", "Repositories that wait for local capacity and never dispatch fallback")
	flag.StringVar(&cfg.Infrastructure, "infrastructure", "", "Infrastructure repository (OWNER/REPOSITORY)")
	flag.StringVar(&cfg.Fallback, "fallback-runner", "", "Linux fallback target as a JSON label string or array")
	flag.StringVar(&macOSFallback, "macos-fallback-runner", "", "Enable yieldd-macos with this fallback target as a JSON label string or array")
	flag.StringVar(&repositoryRoutes, "repository-routes", "", "JSON array of per-repository infrastructure and Linux fallback overrides")
	flag.IntVar(&maxFallbackRunners, "max-fallback-runners", defaultMaxFallbackRunners, fmt.Sprintf("Maximum active hosted bootstraps per repository/platform queue (1-%d)", maximumAssignments))
	flag.StringVar(&directory, "state-dir", "", "Absolute private state directory")
	flag.Func("recover", "Recover one exact OWNER/REPOSITORY/PLATFORM/RUNNER", func(target string) error {
		if target == "" || recoverTarget != "" {
			return errors.New("provide exactly one recovery target")
		}
		recoverTarget = target
		return nil
	})
	flag.BoolVar(&recoverAll, "recover-all", false, "Cancel and clean up every recorded assignment in this deployment")
	flag.StringVar(&cfg.DeviceID, "device-id", "", "UUID of the connected Apple Silicon Mac")
	flag.StringVar(&clientListen, "client-listen", "", "HTTP address behind an HTTPS proxy; use loopback on the host or 0.0.0.0 inside the Compose container")
	flag.BoolVar(&allowNonLoopbackClientListen, "allow-non-loopback-client-listen", false, "Allow cleartext device HTTP on an unspecified IP inside a container with a loopback-only published port")
	flag.Parse()
	recoverOnly := recoverAll || recoverTarget != ""
	if recoverAll && recoverTarget != "" {
		return errors.New("choose one of --recover and --recover-all")
	}
	if flag.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if maxFallbackRunners < 1 || maxFallbackRunners > maximumAssignments {
		return fmt.Errorf("max-fallback-runners must be between 1 and %d", maximumAssignments)
	}
	configs, err := repositoryConfigs(cfg, repositories, localOnly, macOSFallback, repositoryRoutes)
	if err != nil {
		return err
	}
	if err := configureEC2(configs, os.Getenv("YIELDD_EC2")); err != nil {
		return err
	}
	if !filepath.IsAbs(directory) {
		return errors.New("state directory must be absolute")
	}
	if (cfg.DeviceID == "") != (clientListen == "") && !recoverOnly {
		return errors.New("device-id and client-listen must be supplied together")
	}
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		return errors.New("GH_TOKEN is required on the coordinator; it is never sent to runners")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	root, err := openRepositoryStore(directory, configs)
	if err != nil {
		return err
	}
	defer root.Close()
	if recoverTarget != "" {
		return recoverAssignment(ctx, directory, configs, recoverTarget, token)
	}
	deviceToken := os.Getenv("YIELDD_CLIENT_TOKEN")
	var deviceListener net.Listener
	if clientListen != "" && !recoverOnly {
		var err error
		deviceListener, err = listenForDevice(clientListen, deviceToken, allowNonLoopbackClientListen)
		if err != nil {
			return err
		}
		defer deviceListener.Close()
	}
	mux := http.NewServeMux()
	var workers []*platformCoordinator
	defer func() { closeCoordinators(workers...) }()
	platforms := map[string][]*coordinatorLoop{}
	for _, c := range configs {
		path := filepath.Join(directory, queueDirectory(c))
		worker, err := openPlatformCoordinator(ctx, c, path, token, recoverOnly, maxFallbackRunners)
		if err != nil {
			return err
		}
		workers = append(workers, worker)
		if c.EC2.Repository != "" {
			mux.HandleFunc("POST /v1/ec2/{runner}/{op}", worker.loop.ec2Handler)
		}
		platforms[c.platform()] = append(platforms[c.platform()], worker.loop)
	}
	for _, platform := range []string{"linux", "macos"} {
		loops := platforms[platform]
		if len(loops) == 0 {
			continue
		}
		router, err := newDeviceRouter(cfg.DeviceID, loops)
		if err != nil {
			return err
		}
		handler := router.deviceHandler(deviceToken)
		if platform == "macos" {
			mux.Handle("/v1/macos/", platformDeviceHandler(handler))
		} else {
			mux.Handle("/", handler)
		}
	}
	if deviceListener != nil {
		if !deviceListener.Addr().(*net.TCPAddr).IP.IsLoopback() {
			slog.Warn("Device HTTP is unencrypted; restrict the container's published port to host loopback and use an HTTPS proxy")
		}
		server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 90 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
		server.BaseContext = func(net.Listener) context.Context { return ctx }
		done := make(chan struct{})
		go func() {
			defer close(done)
			if err := server.Serve(deviceListener); err != nil && !errors.Is(err, http.ErrServerClosed) {
				slog.Error("Device listener stopped", "error", err)
				stop()
			}
		}()
		defer func() {
			if err := drainDeviceHTTP(server); err != nil {
				slog.Warn("Device HTTP drain timed out", "error", err)
			}
			<-done
		}()
		slog.Info("Listening for connected Mac", "address", clientListen, "device", cfg.DeviceID)
	}
	results := make(chan error, len(workers))
	for _, worker := range workers {
		go func() {
			err := worker.run(ctx, recoverOnly)
			if err != nil && !onlyCancellation(err) {
				worker.loop.worker.logger.Error("Queue stopped; recovery state retained", "error", err)
			}
			results <- err
		}()
	}
	err = waitForCoordinators(results, len(workers), recoverOnly)
	stop()
	if err != nil {
		return err
	}
	slog.Info("Stopped; any active assignment is recorded for reconciliation on restart")
	return nil
}

func waitForCoordinators(results <-chan error, count int, recoverOnly bool) error {
	var failures []error
	for range count {
		err := <-results
		if err != nil && (recoverOnly || !onlyCancellation(err)) {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func platformDeviceHandler(handler http.Handler) http.Handler {
	return http.StripPrefix("/v1/macos", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.URL.Path = "/v1" + r.URL.Path
		handler.ServeHTTP(w, r)
	}))
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

func recoverAssignment(ctx context.Context, directory string, configs []config, target, token string) error {
	split := strings.LastIndexByte(target, '/')
	if split < 0 || !runnerNamePattern.MatchString(target[split+1:]) {
		return errors.New("--recover requires OWNER/REPOSITORY/PLATFORM/RUNNER")
	}
	queue, runner := target[:split], target[split+1:]
	for _, cfg := range configs {
		if !strings.EqualFold(queue, cfg.Repository+"/"+cfg.platform()) {
			continue
		}
		path := filepath.Join(directory, queueDirectory(cfg))
		if _, err := os.Stat(filepath.Join(path, "state.json")); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return errors.New("no such assignment in the selected queue")
			}
			return err
		}
		store, err := openStore(path)
		if err != nil {
			return err
		}
		defer store.Close()
		saved, err := store.read()
		if err != nil {
			return err
		}
		l := saved.Leases[runner]
		if l == nil {
			return errors.New("no such assignment in the selected queue")
		}
		if !saved.Config.sameRoute(cfg) {
			return errors.New("recover with the original queue configuration")
		}
		c, err := newQueueWorker(saved, store, token, 0, true)
		if err != nil {
			return err
		}
		c.device = newDeviceQueue(nil)
		return c.assigned(runner).recover(ctx)
	}
	return errors.New("recovery target does not identify a configured queue")
}

func (a *assignment) recover(ctx context.Context) error {
	l := a.lease
	a.logger.Info("Recovering selected assignment", "runner", l.Name, "registration", l.RunnerID, "dispatch_intent", l.DispatchIntent, "workflow_run", l.RunID, "cleanup_intent", l.CleanupIntent)
	return recoverUntilDone(ctx, func() (bool, error) { return a.reconcile(ctx, true) })
}

func recoverUntilDone(ctx context.Context, attempt func() (bool, error)) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		done, err := attempt()
		if err != nil || done {
			return err
		}
		if err := waitForRetry(ctx, cleanupRetryDelay); err != nil {
			return err
		}
	}
}
