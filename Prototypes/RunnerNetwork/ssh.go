package main

import (
	"context"
	"io"
	"net"
	"sync"
	"time"

	"github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
)

// Only this fixed host-to-guest route is exposed, on a loopback ephemeral port.
// There is no guest-accessible forwarding API.
func forwardSSH(ctx context.Context, network *virtualnetwork.VirtualNetwork, listener net.Listener) {
	var workers sync.WaitGroup
	defer workers.Wait()
	slots := make(chan struct{}, 4)
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
		default:
			client.Close()
			continue
		}
		workers.Add(1)
		go func() {
			defer workers.Done()
			defer func() { <-slots }()
			defer client.Close()
			stop := context.AfterFunc(ctx, func() { client.Close() })
			defer stop()
			dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			guest, err := network.DialContextTCP(dialCtx, guestIP+":22")
			cancel()
			if err != nil {
				return
			}
			defer guest.Close()
			stopGuest := context.AfterFunc(ctx, func() { guest.Close() })
			defer stopGuest()
			done := make(chan struct{})
			go func() { defer close(done); io.Copy(client, guest); client.Close() }()
			io.Copy(guest, client)
			guest.Close()
			<-done
		}()
	}
}
