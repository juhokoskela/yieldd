package main

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v4"
)

func sdkAuthentication(t *testing.T) func(*http.Request, string) (int, string) {
	t.Helper()
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString([]byte("test-only"))
	if err != nil {
		t.Fatal(err)
	}
	return func(request *http.Request, tenant string) (int, string) {
		switch {
		case request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/registration-token"):
			return http.StatusCreated, `{"token":"test-registration-token"}`
		case request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/runner-registration"):
			return http.StatusOK, fmt.Sprintf(`{"url":%q,"token":%q}`, tenant, token)
		default:
			return 0, ""
		}
	}
}
