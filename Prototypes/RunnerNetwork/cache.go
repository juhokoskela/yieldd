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
	cacheAddress      = gatewayIP + ":7341"
	nativeDiskAddress = gatewayIP + ":7342"
	cacheRPC          = "/twirp/github.actions.results.api.v1.CacheService/"
	artifactRPC       = "/twirp/github.actions.results.api.v1.ArtifactService/"
	maxTransferPaths  = 4096
)

type relayCache struct {
	client    *http.Client
	proxy     *httputil.ReverseProxy
	artifacts *httputil.ReverseProxy
	native    http.Handler
	mu        sync.Mutex
	bound     bool
	digest    [sha256.Size]byte
	transfers map[string]struct{}
}

func newRelayCache(socket, directory string, results *http.Transport) *relayCache {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", socket)
		},
		MaxConnsPerHost: 8, MaxIdleConnsPerHost: 8, IdleConnTimeout: time.Minute, ResponseHeaderTimeout: time.Minute,
	}
	// A job may open its native disk while all eight archive connections are streaming.
	verifyTransport := transport.Clone()
	verifyTransport.MaxConnsPerHost = 1
	verifyTransport.MaxIdleConnsPerHost = 1
	c := &relayCache{client: &http.Client{Transport: verifyTransport, Timeout: 10 * time.Second}, transfers: make(map[string]struct{})}
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
	c.artifacts = &httputil.ReverseProxy{
		Transport: results,
		ErrorLog:  log.New(io.Discard, "", 0),
		Rewrite: func(p *httputil.ProxyRequest) {
			p.Out.URL.Scheme, p.Out.URL.Host, p.Out.Host = "https", resultsHost, resultsHost
			p.Out.Header = make(http.Header)
			for _, key := range []string{"Authorization", "Content-Type", "Accept", "User-Agent"} {
				if value := p.In.Header.Get(key); value != "" {
					p.Out.Header.Set(key, value)
				}
			}
		},
		ModifyResponse: func(r *http.Response) error {
			if r.StatusCode >= 300 && r.StatusCode < 400 {
				return errors.New("unexpected redirect from artifact metadata service")
			}
			r.Header.Del("X-Yieldd-Transfer")
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "GitHub artifact service unavailable", http.StatusBadGateway)
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
	var upstream http.Handler
	switch p {
	case cacheRPC + "GetCacheEntryDownloadURL", cacheRPC + "CreateCacheEntry", cacheRPC + "FinalizeCacheEntryUpload":
		upstream = c.proxy
	case artifactRPC + "CreateArtifact", artifactRPC + "FinalizeArtifact", artifactRPC + "ListArtifacts",
		artifactRPC + "GetSignedArtifactURL", artifactRPC + "DeleteArtifact":
		upstream = c.artifacts
	case "/yieldd/native/open", "/yieldd/native/save":
		upstream = c.native
	}
	if upstream == nil || r.Method != http.MethodPost || r.URL.RawQuery != "" {
		http.NotFound(w, r)
		return
	}
	if !c.matches(r.Header.Get("Authorization")) {
		http.Error(w, "job authorization required", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
	upstream.ServeHTTP(w, r)
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
	digest := sha256.Sum256([]byte(authorization))
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bound && subtle.ConstantTimeCompare(digest[:], c.digest[:]) == 1
}

func (c *relayCache) bind(w http.ResponseWriter, r *http.Request) {
	authorization := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(authorization, "Bearer ")
	if !ok || token == "" {
		http.Error(w, "job authorization required", http.StatusUnauthorized)
		return
	}
	digest := sha256.Sum256([]byte(authorization))
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.bound && subtle.ConstantTimeCompare(c.digest[:], digest[:]) != 1 {
		http.Error(w, "runner already bound", http.StatusConflict)
		return
	}
	// Binding pins the credential delivered to this VM before workflow code runs.
	// The cache backend checks the signature and grants when bytes are requested.
	// An artifact-only job may have a valid runtime token with no cache grants.
	c.bound, c.digest = true, digest
	w.WriteHeader(http.StatusNoContent)
}

func (c *relayCache) verify(ctx context.Context, authorization string) (nativeCacheGrants, error) {
	var grants nativeCacheGrants
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://cache/yieldd/verify", nil)
	if err != nil {
		return grants, err
	}
	req.Header.Set("Authorization", authorization)
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
