package pki

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"testing"
)

func TestValidateSignedLeaf_Success(t *testing.T) {
	caPair, caCert, err := newCA("test-ca")
	if err != nil {
		t.Fatalf("newCA: %v", err)
	}
	spec := leafSpec{
		CommonName: "kube-apiserver",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		SANs:       []string{"127.0.0.1", "localhost"},
	}
	leafPair, err := newLeaf(caCert, caPair, spec)
	if err != nil {
		t.Fatalf("newLeaf: %v", err)
	}
	leafCert, err := certFromPEM(leafPair.CertPEM)
	if err != nil {
		t.Fatalf("parse leaf cert: %v", err)
	}
	if err := validateSignedLeaf("test-ca", caCert, leafCert, spec); err != nil {
		t.Fatalf("validateSignedLeaf should succeed: %v", err)
	}
}

func TestValidateSignedLeaf_FailsOnWrongCA(t *testing.T) {
	caPairA, caCertA, err := newCA("ca-a")
	if err != nil {
		t.Fatalf("newCA A: %v", err)
	}
	_, caCertB, err := newCA("ca-b")
	if err != nil {
		t.Fatalf("newCA B: %v", err)
	}
	spec := leafSpec{CommonName: "front-proxy-client", Usages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	leafPair, err := newLeaf(caCertA, caPairA, spec)
	if err != nil {
		t.Fatalf("newLeaf: %v", err)
	}
	leafCert, err := certFromPEM(leafPair.CertPEM)
	if err != nil {
		t.Fatalf("parse leaf cert: %v", err)
	}
	if err := validateSignedLeaf("ca-b", caCertB, leafCert, spec); err == nil {
		t.Fatalf("expected signature validation error")
	}
}

func TestValidateSignedLeaf_FailsOnEKUMismatch(t *testing.T) {
	caPair, caCert, err := newCA("test-ca")
	if err != nil {
		t.Fatalf("newCA: %v", err)
	}
	certSpec := leafSpec{CommonName: "kube-etcd-healthcheck-client", Usages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	leafPair, err := newLeaf(caCert, caPair, certSpec)
	if err != nil {
		t.Fatalf("newLeaf: %v", err)
	}
	leafCert, err := certFromPEM(leafPair.CertPEM)
	if err != nil {
		t.Fatalf("parse leaf cert: %v", err)
	}
	expectedSpec := leafSpec{CommonName: "kube-etcd-healthcheck-client", Usages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	if err := validateSignedLeaf("test-ca", caCert, leafCert, expectedSpec); err == nil {
		t.Fatalf("expected EKU mismatch error")
	}
}

func TestValidateLeafPrivateKeyMatchesCert(t *testing.T) {
	caPair, caCert, err := newCA("test-ca")
	if err != nil {
		t.Fatalf("newCA: %v", err)
	}
	spec := leafSpec{CommonName: "kube-apiserver", Usages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafPair, err := newLeaf(caCert, caPair, spec)
	if err != nil {
		t.Fatalf("newLeaf: %v", err)
	}
	leafCert, err := certFromPEM(leafPair.CertPEM)
	if err != nil {
		t.Fatalf("parse leaf cert: %v", err)
	}
	leafKey, err := decodeRSA(leafPair.KeyPEM)
	if err != nil {
		t.Fatalf("decode leaf key: %v", err)
	}
	if err := validateLeafPrivateKeyMatchesCert(leafKey, leafCert); err != nil {
		t.Fatalf("expected key match, got: %v", err)
	}

	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate other key: %v", err)
	}
	if err := validateLeafPrivateKeyMatchesCert(otherKey, leafCert); err == nil {
		t.Fatalf("expected key mismatch error")
	}
}
