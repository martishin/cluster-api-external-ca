package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"strings"
	"testing"
)

type fakeServerResolver struct {
	url   string
	err   error
	calls int
}

func (f *fakeServerResolver) GetClusterServerURL(_ context.Context, _, _ string) (string, error) {
	f.calls++
	return f.url, f.err
}

func TestResolveKubeconfigServer_UsesOverride(t *testing.T) {
	r := &fakeServerResolver{url: "https://ignored:6443"}
	got, err := resolveKubeconfigServer(context.Background(), r, "default", "c1", "https://override:6443")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if got != "https://override:6443" {
		t.Fatalf("expected override server, got %q", got)
	}
	if r.calls != 0 {
		t.Fatalf("resolver should not be called when override is set")
	}
}

func TestResolveKubeconfigServer_UsesResolvedEndpoint(t *testing.T) {
	r := &fakeServerResolver{url: "https://api.example:6443"}
	got, err := resolveKubeconfigServer(context.Background(), r, "default", "c1", "")
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if got != "https://api.example:6443" {
		t.Fatalf("unexpected server: %q", got)
	}
	if r.calls != 1 {
		t.Fatalf("expected resolver call")
	}
}

func TestResolveKubeconfigServer_ResolverError(t *testing.T) {
	r := &fakeServerResolver{err: errors.New("boom")}
	_, err := resolveKubeconfigServer(context.Background(), r, "default", "c1", "")
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveKubeconfigServer_EmptyEndpointRequiresServer(t *testing.T) {
	r := &fakeServerResolver{}
	_, err := resolveKubeconfigServer(context.Background(), r, "default", "c1", "")
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), "pass --server") {
		t.Fatalf("expected guidance to pass --server, got: %v", err)
	}
}

func TestSplitCSV(t *testing.T) {
	got := splitCSV("a, b, ,c,,  d ")
	want := []string{"a", "b", "c", "d"}
	if len(got) != len(want) {
		t.Fatalf("unexpected length: got=%d want=%d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("unexpected item[%d]: got=%q want=%q", i, got[i], want[i])
		}
	}
}

func TestValidateServiceAccountKeyPair_Valid(t *testing.T) {
	pubPEM, keyPEM := mustRSAKeyPairPEM(t)
	if err := validateServiceAccountKeyPair(pubPEM, keyPEM); err != nil {
		t.Fatalf("expected valid keypair, got error: %v", err)
	}
}

func TestValidateServiceAccountKeyPair_Mismatch(t *testing.T) {
	pubPEM, _ := mustRSAKeyPairPEM(t)
	_, otherKey := mustRSAKeyPairPEM(t)
	if err := validateServiceAccountKeyPair(pubPEM, otherKey); err == nil {
		t.Fatalf("expected mismatch error")
	}
}

func mustRSAKeyPairPEM(t *testing.T) ([]byte, []byte) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	return pubPEM, keyPEM
}
