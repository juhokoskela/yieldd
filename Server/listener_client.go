package main

import (
	"context"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
)

// The upstream listener deliberately strips cancellation while acknowledging
// messages and acquiring jobs. Bind those calls back to their worker's lifetime.
type shutdownAwareListenerClient struct {
	listener.Client
	lifetime context.Context
	loop     *coordinatorLoop
}

// The SDK acknowledges a message before invoking job callbacks. Journal EC2
// completions on receipt so a failed write leaves the message with GitHub.
func (c shutdownAwareListenerClient) GetMessage(ctx context.Context, lastID, capacity int) (*scaleset.RunnerScaleSetMessage, error) {
	msg, err := c.Client.GetMessage(ctx, lastID, capacity)
	if err != nil || msg == nil || (len(msg.JobCompletedMessages) == 0 && len(msg.JobStartedMessages) == 0) || c.loop.worker.fleet == nil {
		return msg, err
	}
	err = c.loop.invoke(ctx, func(context.Context) error {
		for _, job := range msg.JobStartedMessages {
			if err := c.loop.worker.recordEC2Start(job); err != nil {
				return err
			}
		}
		for _, job := range msg.JobCompletedMessages {
			if err := c.loop.worker.recordEC2Job(job, jobSucceededResult(job.Result)); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return msg, nil
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
