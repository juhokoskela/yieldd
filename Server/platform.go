package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

// Each repository/platform queue owns a journal, message session, and serialized lifecycle.
type platformCoordinator struct {
	cancel     context.CancelFunc
	store      *stateStore
	loop       *coordinatorLoop
	session    listenerSession
	messages   *listener.Listener
	scaleSetID int
	newSession func(context.Context) (listenerSession, error)
}

type listenerSession interface {
	listener.Client
	Close(context.Context) error
}

const listenerRetryDelay = 5 * time.Second
const listenerMaximumRetryDelay = time.Minute

func openPlatformCoordinator(ctx context.Context, cfg config, directory, token string, recoverOnly bool, maxFallbackRunners int) (_ *platformCoordinator, err error) {
	defer func() {
		if err != nil {
			err = fmt.Errorf("repository %s platform %s: %w", cfg.Repository, cfg.platform(), err)
		}
	}()
	store, err := openStore(directory)
	if err != nil {
		return nil, err
	}
	p := &platformCoordinator{store: store}
	defer func() {
		if err != nil {
			closeCoordinators(p)
		}
	}()
	saved, err := store.load(cfg)
	if err != nil {
		return nil, err
	}
	logger := slog.Default().With("repository", cfg.Repository, "platform", cfg.platform())
	client, err := newScaleSetClient("https://github.com/"+cfg.Repository, token)
	if err != nil {
		return nil, &sdkError{"initialize client", err}
	}
	api := &githubAPI{base: "https://api.github.com", token: token, infrastructure: cfg.Infrastructure, client: &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	worker := &coordinator{state: saved, save: store.save, runners: client, bootstrap: api, logger: logger, maxFallbackRunners: maxFallbackRunners}
	loopContext, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	p.loop = newCoordinatorLoop(loopContext, worker)
	if recoverOnly {
		return p, nil
	}
	id, err := ensurePlatformScaleSet(ctx, client, cfg, saved.ScaleSetID)
	if err != nil {
		return nil, err
	}
	if saved.ScaleSetID == 0 {
		saved.ScaleSetID = id
		if err := store.save(saved); err != nil {
			return nil, err
		}
	}
	owner := saved.Owner
	p.scaleSetID = id
	p.newSession = func(ctx context.Context) (listenerSession, error) {
		return client.MessageSessionClient(ctx, id, owner)
	}
	if err := p.openMessages(ctx); err != nil {
		return nil, err
	}
	return p, nil
}

func newScaleSetClient(configURL, token string) (*scaleset.Client, error) {
	// A lost registration POST must never be retried automatically. Let the SDK
	// create separate HTTP clients, rather than sharing its mutable auth policy.
	return scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
		GitHubConfigURL: configURL, PersonalAccessToken: token,
		SystemInfo: scaleset.SystemInfo{System: "yieldd", Version: "prototype", Subsystem: "coordinator"},
	}, scaleset.WithRetryMax(0), scaleset.WithTimeout(60*time.Second))
}

func closeCoordinators(workers ...*platformCoordinator) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var pending sync.WaitGroup
	for _, worker := range workers {
		pending.Go(func() { worker.close(ctx) })
	}
	pending.Wait()
}

func (p *platformCoordinator) close(ctx context.Context) {
	if p.cancel != nil {
		p.cancel()
	}
	if p.session != nil {
		if err := p.session.Close(ctx); err != nil {
			slog.Error("Close scale set session", "error", &sdkError{"close message session", err})
		} else {
			p.session = nil
		}
	}
	if err := p.store.Close(); err != nil {
		slog.Error("Close state store", "error", err)
	}
}

func (p *platformCoordinator) run(ctx context.Context, recoverOnly bool) error {
	if recoverOnly {
		for {
			done, err := p.loop.worker.reconcile(ctx, true)
			if err != nil || done {
				return err
			}
			if err := waitForRetry(ctx, cleanupRetryDelay); err != nil {
				return err
			}
		}
	}
	defer p.cancel()
	worker := p.loop.worker
	// Remove a failed waiter's FIFO entry, never its issued capacity reservation.
	defer worker.device.forget(worker.state.Owner)
	worker.logger.Info("Serving scale set", "scale_set", worker.state.ScaleSetID, "capacity", maximumAssignments, "fallback_capacity", worker.maxFallbackRunners, "local_only", worker.state.Config.LocalOnly, "fallback", worker.state.Config.Fallback)
	done := make(chan error, 1)
	go func() { done <- p.loop.run(); p.cancel() }()
	err := p.listen()
	p.cancel()
	loopErr := <-done
	if loopErr != nil && !onlyCancellation(loopErr) {
		return loopErr
	}
	if err != nil && !onlyCancellation(err) {
		return err
	}
	return nil
}

func (p *platformCoordinator) openMessages(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	session, err := p.newSession(ctx)
	if err != nil {
		return &sdkError{"open message session", err}
	}
	p.session = session
	p.messages, err = listener.New(shutdownAwareListenerClient{Client: session, lifetime: p.loop.ctx}, listener.Config{ScaleSetID: p.scaleSetID, MaxRunners: maximumAssignments})
	return err
}

func (p *platformCoordinator) listen() error {
	ctx := p.loop.ctx
	delay := listenerRetryDelay
	for {
		started := time.Now()
		err := p.messages.Run(ctx, p.loop)
		var callback *callbackError
		if errors.As(err, &callback) {
			return callback
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := p.loop.suspendProvisioning(); err != nil {
			return err
		}
		if time.Since(started) >= listenerMaximumRetryDelay {
			delay = listenerRetryDelay
		}
		p.loop.worker.logger.Warn("Demand listener interrupted; retaining assignments and reconnecting", "retry_delay", delay, "error", &sdkError{"listen for demand", err})
		for {
			if err := waitForRetry(ctx, delay); err != nil {
				return err
			}
			delay = min(delay*2, listenerMaximumRetryDelay)
			if p.session != nil {
				closeCtx, cancel := context.WithTimeout(ctx, listenerRetryDelay)
				err := p.session.Close(closeCtx)
				cancel()
				if err == nil {
					p.session = nil
				}
				if err != nil && ctx.Err() == nil {
					p.loop.worker.logger.Warn("Previous demand session could not be closed", "error", &sdkError{"close message session", err})
				}
			}
			if err := p.openMessages(ctx); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				p.loop.worker.logger.Warn("Demand listener reconnect failed; retaining assignments", "retry_delay", delay, "error", err)
				continue
			}
			p.loop.worker.logger.Info("Demand listener reconnected", "scale_set", p.scaleSetID)
			break
		}
	}
}

type scaleSetAPI interface {
	GetRunnerScaleSet(context.Context, int, string) (*scaleset.RunnerScaleSet, error)
	GetRunnerScaleSetByID(context.Context, int) (*scaleset.RunnerScaleSet, error)
	CreateRunnerScaleSet(context.Context, *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error)
	UpdateRunnerScaleSet(context.Context, int, *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error)
}

func ensurePlatformScaleSet(ctx context.Context, client scaleSetAPI, cfg config, savedID int) (int, error) {
	name := cfg.scaleSetName()
	desired := &scaleset.RunnerScaleSet{Name: name, RunnerGroupID: 1, Labels: []scaleset.Label{{Name: name, Type: "System"}}, RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true}}
	if cfg.platform() == "linux" {
		desired.Labels = append(desired.Labels, scaleset.Label{Name: "yieldd-linux", Type: "System"})
	}
	var set *scaleset.RunnerScaleSet
	var err error
	operation := fmt.Sprintf("find scale set %q", name)
	if savedID != 0 {
		operation = fmt.Sprintf("get saved scale set %d", savedID)
		set, err = client.GetRunnerScaleSetByID(ctx, savedID)
	} else {
		set, err = client.GetRunnerScaleSet(ctx, 1, name)
	}
	if err != nil {
		return 0, &sdkError{operation, err}
	}
	baseLabels := []scaleset.Label{{Name: name}}
	if set == nil {
		if savedID != 0 {
			return 0, errors.New("saved scale set is missing; refusing to replace its identity")
		}
		set, err = client.CreateRunnerScaleSet(ctx, desired)
	} else {
		if set.ID <= 0 || set.Name != name || set.RunnerGroupID != 1 || (savedID != 0 && set.ID != savedID) {
			return 0, errors.New("scale set identity does not match its platform")
		}
		savedID = set.ID
		if !sameLabels(set.Labels, baseLabels) && !sameLabels(set.Labels, desired.Labels) {
			return 0, fmt.Errorf("scale set %q (%d) has unexpected labels %q", name, set.ID, scaleSetLabelNames(set.Labels))
		}
		if !sameLabels(set.Labels, desired.Labels) {
			set, err = client.UpdateRunnerScaleSet(ctx, set.ID, desired)
		}
	}
	if err != nil {
		return 0, &sdkError{"configure scale set", err}
	}
	if set == nil || set.ID <= 0 || (savedID != 0 && set.ID != savedID) || set.Name != name || set.RunnerGroupID != 1 {
		return 0, fmt.Errorf("invalid identity in GitHub response for scale set %q", name)
	}
	if !sameLabels(set.Labels, desired.Labels) {
		if cfg.platform() != "linux" || !sameLabels(set.Labels, baseLabels) {
			return 0, fmt.Errorf("scale set %q (%d) has labels %q; expected %q", name, set.ID, scaleSetLabelNames(set.Labels), scaleSetLabelNames(desired.Labels))
		}
		slog.Warn("GitHub did not retain the Linux alias; use runs-on: yieldd",
			"repository", cfg.Repository, "scale_set", set.ID, "alias", "yieldd-linux")
	}
	return set.ID, nil
}

func scaleSetLabelNames(labels []scaleset.Label) []string {
	names := make([]string, len(labels))
	for i, label := range labels {
		names[i] = label.Name
	}
	return names
}

func sameLabels(a, b []scaleset.Label) bool {
	if len(a) != len(b) {
		return false
	}
	for _, want := range b {
		if !slices.ContainsFunc(a, func(got scaleset.Label) bool { return got.Name == want.Name }) {
			return false
		}
	}
	return true
}
