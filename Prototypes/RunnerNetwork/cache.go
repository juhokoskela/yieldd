package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"path"
	"strings"
	"sync"
	"time"
)

const (
	cacheAddress     = gatewayIP + ":7341"
	cacheRPC         = "/twirp/github.actions.results.api.v1.CacheService/"
	artifactRPC      = "/twirp/github.actions.results.api.v1.ArtifactService/"
	maxTransferPaths = 4096
)

type relayCache struct {
	client    *http.Client
	proxy     *httputil.ReverseProxy
	native    http.Handler
	mu        sync.Mutex
	bound     bool
	digest    [sha256.Size]byte
	transfers map[string]struct{}
}

func newRelayCache(socket, directory string) *relayCache {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", socket)
		},
		MaxIdleConns: 8, IdleConnTimeout: time.Minute, ResponseHeaderTimeout: time.Minute,
	}
	c := &relayCache{client: &http.Client{Transport: transport, Timeout: 10 * time.Second}, transfers: make(map[string]struct{})}
	c.native = nativeCacheHandler(directory, c.verify)
	c.proxy = &httputil.ReverseProxy{
		Transport: transport,
		ErrorLog:  log.New(io.Discard, "", 0), // Backend errors can contain signed blob URLs.
		Rewrite: func(p *httputil.ProxyRequest) {
			p.Out.URL.Scheme, p.Out.URL.Host, p.Out.Host = "http", "cache", "cache"
			p.Out.Header.Del("X-Yieldd-Transfer")
		},
		ModifyResponse: c.rememberTransfer,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "cache service unavailable", http.StatusBadGateway)
		},
	}
	return c
}

// Called only through a socket inside this guest's private network stack. The trusted
// runner binds its token before executing any hooks or workflow code.
func (c *relayCache) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if r.URL.IsAbs() || r.URL.RawPath != "" || path.Clean(p) != p {
		http.NotFound(w, r)
		return
	}
	if r.Method == http.MethodPost && p == "/yieldd/bind" {
		c.bind(w, r)
		return
	}
	if transferPath(p) {
		c.mu.Lock()
		_, ok := c.transfers[p]
		c.mu.Unlock()
		want := http.MethodPut
		if strings.HasPrefix(p, "/download/") {
			want = http.MethodGet
		}
		if !ok || (r.Method != want && !(want == http.MethodGet && r.Method == http.MethodHead)) {
			http.Error(w, "transfer unavailable", http.StatusForbidden)
			return
		}
		c.proxy.ServeHTTP(w, r)
		return
	}
	cacheMethod := rpcMethod(p, cacheRPC)
	artifactMethod := rpcMethod(p, artifactRPC)
	native := p == "/yieldd/native/open" || p == "/yieldd/native/save"
	if r.Method != http.MethodPost || (!cacheMethod && !artifactMethod && !native) {
		http.NotFound(w, r)
		return
	}
	if !c.matches(r.Header.Get("Authorization")) {
		http.Error(w, "job authorization required", http.StatusUnauthorized)
		return
	}
	// Twirp requests contain metadata. Archive bytes only use the signed transfer routes.
	r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
	if native {
		c.native.ServeHTTP(w, r)
		return
	}
	c.proxy.ServeHTTP(w, r)
}

func rpcMethod(p, service string) bool {
	method, ok := strings.CutPrefix(p, service)
	return ok && method != "" && !strings.Contains(method, "/")
}

func transferPath(p string) bool {
	for _, prefix := range []string{"/devstoreaccount1/upload/", "/download/"} {
		if id, ok := strings.CutPrefix(p, prefix); ok {
			return id != "" && !strings.Contains(id, "/") && path.Clean(p) == p
		}
	}
	return false
}

func (c *relayCache) rememberTransfer(resp *http.Response) error {
	p := resp.Header.Get("X-Yieldd-Transfer")
	resp.Header.Del("X-Yieldd-Transfer")
	if p == "" {
		return nil
	}
	if !strings.HasPrefix(resp.Request.URL.Path, cacheRPC) || !transferPath(p) || resp.StatusCode != http.StatusOK {
		return errors.New("invalid cache transfer response")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.transfers[p]; !exists && len(c.transfers) >= maxTransferPaths {
		return errors.New("too many transfers in one job")
	}
	c.transfers[p] = struct{}{}
	return nil
}

func (c *relayCache) matches(authorization string) bool {
	token, ok := strings.CutPrefix(authorization, "Bearer ")
	if !ok || token == "" {
		return false
	}
	digest := sha256.Sum256([]byte(token))
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bound && subtle.ConstantTimeCompare(digest[:], c.digest[:]) == 1
}

func (c *relayCache) bind(w http.ResponseWriter, r *http.Request) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		http.Error(w, "job authorization required", http.StatusUnauthorized)
		return
	}
	if _, err := c.verify(r.Context(), token); err != nil {
		http.Error(w, "job authorization rejected", http.StatusUnauthorized)
		return
	}
	digest := sha256.Sum256([]byte(token))
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.bound && subtle.ConstantTimeCompare(c.digest[:], digest[:]) != 1 {
		http.Error(w, "runner already bound", http.StatusConflict)
		return
	}
	c.bound, c.digest = true, digest
	w.WriteHeader(http.StatusNoContent)
}

func (c *relayCache) verify(ctx context.Context, token string) (nativeCacheGrants, error) {
	var grants nativeCacheGrants
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://cache/yieldd/verify", nil)
	if err != nil {
		return grants, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := c.client.Do(req)
	if err != nil {
		return grants, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return grants, errors.New("job token rejected")
	}
	err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&grants)
	return grants, err
}
