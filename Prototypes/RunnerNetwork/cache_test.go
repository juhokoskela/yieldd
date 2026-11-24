package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Exercise the signed binary and the same relay handlers guests reach. The test owns
// every key, socket and stored byte, including the fixture issuer's private key.
func TestArchiveRouting(t *testing.T) {
	bin := os.Getenv("YIELDD_TEST_CACHE")
	if bin == "" {
		t.Skip("set YIELDD_TEST_CACHE to the packaged archive helper")
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.RawURLEncoding.EncodeToString
	issuer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]string{
			"kid": "fixture", "kty": "RSA", "alg": "RS256", "use": "sig", "n": b64(key.N.Bytes()), "e": "AQAB",
		}}})
	}))
	defer issuer.Close()
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != resultsHost || r.URL.Path != artifactRPC+"CreateArtifact" {
			t.Errorf("unexpected GitHub forwarding: %s", r.URL.Path)
		}
		io.WriteString(w, "fixture artifact")
	}))
	defer origin.Close()
	results := fixtureResultsTransport(t, origin)
	token := func(repo, ref string, permission int) string {
		grants, err := json.Marshal([]map[string]any{{"Scope": ref, "Permission": permission}})
		if err != nil {
			t.Fatal(err)
		}
		claims := map[string]any{"iss": issuer.URL, "exp": time.Now().Add(time.Hour).Unix(), "repository_id": repo}
		if permission != 0 {
			claims["ac"] = string(grants)
		}
		payload, err := json.Marshal(claims)
		if err != nil {
			t.Fatal(err)
		}
		input := b64([]byte(`{"alg":"RS256","kid":"fixture"}`)) + "." + b64(payload)
		hash := sha256.Sum256([]byte(input))
		signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, hash[:])
		if err != nil {
			t.Fatal(err)
		}
		return input + "." + b64(signature)
	}
	dir := socketTestDirectory(t)
	socket := filepath.Join(dir, "cache.sock")
	p := exec.CommandContext(t.Context(), bin)
	p.Dir = dir
	p.Env = []string{"API_BASE_URL=http://" + cacheAddress, "YIELDD_CACHE_SOCKET=" + socket,
		"ACTIONS_TOKEN_ISSUER=" + issuer.URL, "ACTIONS_TOKEN_JWKS_URL=" + issuer.URL + "/jwks",
		`YIELDD_CACHE_POLICY={"trustedGroups":[[{"repositoryID":"123","ref":"refs/heads/main"},{"repositoryID":"456","ref":"refs/heads/master"}]]}`}
	owner, err := p.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	p.Stderr = os.Stderr
	if err = p.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- p.Wait() }()
	t.Cleanup(func() {
		owner.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			p.Process.Kill()
			<-done
			t.Error("cache helper outlived its owner")
		}
	})
	for deadline := time.Now().Add(10 * time.Second); ; {
		if _, err := os.Stat(socket); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("archive socket did not appear")
		}
		time.Sleep(10 * time.Millisecond)
	}
	request := func(c http.Handler, method, route, bearer, body string, status int) []byte {
		t.Helper()
		req := httptest.NewRequestWithContext(context.Background(), method, route, bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		rec := httptest.NewRecorder()
		c.ServeHTTP(rec, req)
		if rec.Code != status {
			t.Fatalf("%s %s: status %d, want %d: %s", method, req.URL.Path, rec.Code, status, rec.Body.Bytes())
		}
		if rec.Header().Get("X-Yieldd-Transfer") != "" {
			t.Fatal("private header reached guest")
		}
		return rec.Body.Bytes()
	}
	newGuest := func(bearer string) *relayCache {
		c := newRelayCache(socket, results)
		t.Cleanup(c.transport.CloseIdleConnections)
		request(c, "POST", "/yieldd/bind", bearer, "", 204)
		return c
	}
	urlField := func(body []byte, key string) *url.URL {
		t.Helper()
		var object map[string]any
		if err := json.Unmarshal(body, &object); err != nil {
			t.Fatal(err)
		}
		s, _ := object[key].(string)
		u, err := url.Parse(s)
		if err != nil || u.Host != cacheAddress {
			t.Fatalf("missing %s in %s", key, body)
		}
		return u
	}
	rpc := func(c *relayCache, name, bearer string, status int) []byte {
		return request(c, "POST", cacheRPC+name, bearer, `{"key":"subprocess-cache-test","version":"v1"}`, status)
	}
	primary := token("123", "refs/heads/main", 3)
	reader := token("456", "refs/heads/master", 1)
	writer := newGuest(primary)
	request(writer, "POST", "/yieldd/bind", reader, "", 409)
	unbound := newRelayCache(socket, results)
	t.Cleanup(unbound.transport.CloseIdleConnections)
	request(unbound, "POST", "/yieldd/bind", "", "", 401)
	noAccess := newGuest("invalid")
	rpc(noAccess, "GetCacheEntryDownloadURL", "invalid", 401)
	rpc(noAccess, "CreateCacheEntry", "invalid", 401)
	artifactOnly := token("123", "refs/heads/main", 0)
	artifactGuest := newGuest(artifactOnly)
	offline := newRelayCache(filepath.Join(dir, "missing-archive.sock"), results)
	t.Cleanup(offline.transport.CloseIdleConnections)
	request(offline, "POST", "/yieldd/bind", artifactOnly, "", 204)
	request(offline, "POST", cacheRPC+"CreateCacheEntry", artifactOnly, "{}", 502)
	if got := request(offline, "POST", artifactRPC+"CreateArtifact", artifactOnly, "{}", 200); string(got) != "fixture artifact" {
		t.Fatal("artifact-only job could not use GitHub")
	}
	rpc(artifactGuest, "CreateCacheEntry", artifactOnly, 401)
	request(writer, "POST", "/yieldd/verify", primary, "", 404)
	request(writer, "GET", "/management-api/cache-entries", primary, "", 404)
	rpc(writer, "CreateCacheEntry", reader, 401)
	up := urlField(rpc(writer, "CreateCacheEntry", primary, 200), "signed_upload_url")
	request(writer, "PUT", up.RequestURI(), "", "local bytes", 201)
	request(writer, "POST", cacheRPC+"FinalizeCacheEntryUpload", primary,
		`{"key":"subprocess-cache-test","version":"v1","size_bytes":"11"}`, 200)
	otherWriter := token("456", "refs/heads/master", 3)
	rpc(newGuest(otherWriter), "CreateCacheEntry", otherWriter, 409)
	shared := newGuest(reader)
	down := urlField(rpc(shared, "GetCacheEntryDownloadURL", reader, 200), "signed_download_url")
	if got := request(shared, "GET", down.RequestURI(), "", "", 200); string(got) != "local bytes" {
		t.Fatalf("unexpected bytes %q", got)
	}
	rpc(shared, "CreateCacheEntry", reader, 403)
	request(shared, "PUT", up.RequestURI(), "", "cannot replace", 403)
	retired := newGuest(token("123", "refs/pull/1/merge", 3))
	request(retired, "GET", down.RequestURI(), "", "", 403)
	request(retired, "POST", cacheRPC+"GetCacheEntryDownloadURL", primary, "{}", 401)
	unknown := token("999", "refs/heads/main", 3)
	isolated := newGuest(unknown)
	if strings.Contains(string(rpc(isolated, "GetCacheEntryDownloadURL", unknown, 200)), "http") {
		t.Fatal("untrusted repository saw shared bytes")
	}
	if got := request(writer, "POST", artifactRPC+"CreateArtifact", primary, "{}", 200); string(got) != "fixture artifact" {
		t.Fatal("artifact forwarding failed")
	}
}

func fixtureResultsTransport(t *testing.T, origin *httptest.Server) *http.Transport {
	t.Helper()
	results := origin.Client().Transport.(*http.Transport).Clone()
	results.TLSClientConfig.ServerName = "example.com" // SAN of the httptest certificate.
	results.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if addr != resultsHost+":443" {
			t.Errorf("unexpected artifact destination %q", addr)
		}
		return (&net.Dialer{}).DialContext(ctx, network, origin.Listener.Addr().String())
	}
	t.Cleanup(results.CloseIdleConnections)
	return results
}

func TestArtifactMetadataRequiresBoundTokenAndPinnedOrigin(t *testing.T) {
	dir := t.TempDir()
	var calls atomic.Int32
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Host != resultsHost || r.Header.Get("Authorization") != "Bearer bound-job" || r.Header.Get("X-Yieldd-Transfer") != "" {
			t.Error("unexpected origin or forwarded credential headers")
		}
		if r.URL.Path == artifactRPC+"ListArtifacts" {
			http.Redirect(w, r, "http://127.0.0.1/private", http.StatusTemporaryRedirect)
			return
		}
		io.WriteString(w, "artifact metadata")
	}))
	defer origin.Close()
	c := newRelayCache(filepath.Join(dir, "absent.sock"), fixtureResultsTransport(t, origin))
	t.Cleanup(c.transport.CloseIdleConnections)
	request := func(route, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", route, strings.NewReader("{}"))
		r.Host = "guest.invalid"
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Set("X-Yieldd-Transfer", "private")
		w := httptest.NewRecorder()
		c.ServeHTTP(w, r)
		return w
	}
	for _, test := range []struct {
		route, token string
		want         int
	}{
		{artifactRPC + "CreateArtifact", "bound-job", 401},
		{"/yieldd/bind", "bound-job", 204},
		{artifactRPC + "CreateArtifact", "other", 401},
		{artifactRPC + "UnknownMethod", "bound-job", 404},
		{artifactRPC + "ListArtifacts?destination=local", "bound-job", 404},
		{cacheRPC + "UnknownMethod", "bound-job", 404},
		{artifactRPC + "ListArtifacts", "bound-job", 502},
		{artifactRPC + "FinalizeArtifact", "bound-job", 200},
	} {
		w := request(test.route, test.token)
		if w.Code != test.want || w.Header().Get("Location") != "" {
			t.Fatalf("%s: %d (want %d)", test.route, w.Code, test.want)
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("origin received %d requests, want 2", got)
	}
}

func TestResultsTransportRejectsOtherDestinations(t *testing.T) {
	transport := githubResultsTransport(new(denialCounters))
	if transport.Proxy != nil || transport.TLSClientConfig != nil && transport.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("results transport must verify TLS and avoid host proxies")
	}
	for _, target := range []string{"127.0.0.1:443", resultsHost + ":80", "github.com:443"} {
		if _, err := transport.DialContext(t.Context(), "tcp", target); !errors.Is(err, errDenied) {
			t.Errorf("expected destination rejection for %s: %v", target, err)
		}
	}
}
