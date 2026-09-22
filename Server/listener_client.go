package main

import (
	"context"

	"github.com/actions/scaleset/listener"
)

// The upstream listener deliberately strips cancellation while acknowledging
// messages and acquiring jobs. Bind those calls back to their worker's lifetime.
type shutdownAwareListenerClient struct {
	listener.Client
	lifetime context.Context
}

func (c shutdownAwareListenerClient) requestContext(ctx context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(c.lifetime, cancel)
	if c.lifetime.Err() != nil {
		cancel()
	}
	return ctx, func() { stop(); cancel() }
}

func (c shutdownAwareListenerClient) DeleteMessage(ctx context.Context, id int) error {
	ctx, cancel := c.requestContext(ctx)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return err
	}
	return c.Client.DeleteMessage(ctx, id)
}

func (c shutdownAwareListenerClient) AcquireJobs(ctx context.Context, ids []int64) ([]int64, error) {
	ctx, cancel := c.requestContext(ctx)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return c.Client.AcquireJobs(ctx, ids)
}
