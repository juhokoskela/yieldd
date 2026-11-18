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
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != artifactRPC+"CreateArtifact" {
			t.Errorf("unexpected GitHub forwarding: %s", r.URL.Path)
		}
		io.WriteString(w, "fixture artifact")
	}))
	defer origin.Close()
	token := func(repo, ref string, permission int) string {
		grants, err := json.Marshal([]map[string]any{{"Scope": ref, "Permission": permission}})
		if err != nil {
			t.Fatal(err)
		}
		payload, err := json.Marshal(map[string]any{"iss": issuer.URL, "exp": time.Now().Add(time.Hour).Unix(), "repository_id": repo, "ac": string(grants)})
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
		"DEFAULT_ACTIONS_RESULTS_URL=" + origin.URL,
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
		c := newRelayCache(socket, dir)
		t.Cleanup(c.client.CloseIdleConnections)
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
	request(writer, "POST", "/yieldd/bind", "invalid", "", 401)
	request(writer, "POST", "/yieldd/verify", primary, "", 404)
	request(writer, "GET", "/management-api/cache-entries", primary, "", 404)
	rpc(writer, "CreateCacheEntry", reader, 401)
	up := urlField(rpc(writer, "CreateCacheEntry", primary, 200), "signed_upload_url")
	request(writer, "PUT", up.RequestURI(), "", "local bytes", 201)
	rpc(writer, "FinalizeCacheEntryUpload", primary, 200)
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
