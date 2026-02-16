package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"testing"
	"time"

	"github.com/martishin/cluster-api-external-ca/internal/kmsserviceapi"
	"github.com/martishin/cluster-api-external-ca/internal/kmsservicegrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

func TestServerGetCA(t *testing.T) {
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: {certPEM: []byte("test-ca")}}}
	resp, err := s.GetCA(context.Background(), wrapperspb.String(kmsserviceapi.CAKubernetes))
	if err != nil {
		t.Fatalf("GetCA failed: %v", err)
	}
	if resp.GetValue() != "test-ca" {
		t.Fatalf("unexpected cert value: %q", resp.GetValue())
	}

	_, err = s.GetCA(context.Background(), wrapperspb.String("unknown"))
	if status.Code(err) != codes.NotFound {
		t.Fatalf("expected NotFound, got %v", status.Code(err))
	}
}

func TestServerSignCSR_Success(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAKubernetes)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: ca}}

	csrPEM := mustNewCSRPEM(t, csrInput{
		commonName:    "kubernetes-admin",
		organizations: []string{"system:masters"},
	})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAKubernetes,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}

	resp, err := s.SignCSR(context.Background(), wrapperspb.String(payload))
	if err != nil {
		t.Fatalf("SignCSR failed: %v", err)
	}
	crt := mustParseCertPEM(t, []byte(resp.GetValue()))
	if crt.Subject.CommonName != "kubernetes-admin" {
		t.Fatalf("unexpected cert CN: %q", crt.Subject.CommonName)
	}
	if !hasExtKeyUsage(crt.ExtKeyUsage, x509.ExtKeyUsageClientAuth) {
		t.Fatalf("expected clientAuth EKU, got %v", crt.ExtKeyUsage)
	}
}

func TestServerSignCSR_SuperAdminSuccess(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAKubernetes)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: ca}}

	csrPEM := mustNewCSRPEM(t, csrInput{
		commonName:    "kubernetes-super-admin",
		organizations: []string{"system:masters"},
	})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAKubernetes,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}

	resp, err := s.SignCSR(context.Background(), wrapperspb.String(payload))
	if err != nil {
		t.Fatalf("SignCSR failed: %v", err)
	}
	crt := mustParseCertPEM(t, []byte(resp.GetValue()))
	if crt.Subject.CommonName != "kubernetes-super-admin" {
		t.Fatalf("unexpected cert CN: %q", crt.Subject.CommonName)
	}
	if !hasExtKeyUsage(crt.ExtKeyUsage, x509.ExtKeyUsageClientAuth) {
		t.Fatalf("expected clientAuth EKU, got %v", crt.ExtKeyUsage)
	}
}

func TestServerSignCSR_InvalidPayload(t *testing.T) {
	s := &server{cas: map[string]*caMaterial{}}
	_, err := s.SignCSR(context.Background(), wrapperspb.String("not-json"))
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %v", status.Code(err))
	}
}

func TestServerSignCSR_UnsupportedCN(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAKubernetes)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: ca}}
	csrPEM := mustNewCSRPEM(t, csrInput{commonName: "unsupported-cn"})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAKubernetes,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}
	_, err = s.SignCSR(context.Background(), wrapperspb.String(payload))
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %v", status.Code(err))
	}
}

func TestServerSignCSR_WrongOrg(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAKubernetes)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: ca}}
	csrPEM := mustNewCSRPEM(t, csrInput{
		commonName:    "kubernetes-admin",
		organizations: []string{"not-system-masters"},
	})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAKubernetes,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}
	_, err = s.SignCSR(context.Background(), wrapperspb.String(payload))
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %v", status.Code(err))
	}
}

func TestServerSignCSR_RequiresSANs(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAKubernetes)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAKubernetes: ca}}
	csrPEM := mustNewCSRPEM(t, csrInput{
		commonName: "kube-apiserver",
	})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAKubernetes,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}
	_, err = s.SignCSR(context.Background(), wrapperspb.String(payload))
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %v", status.Code(err))
	}
}

func TestServerSignCSR_WrongCAForProfile(t *testing.T) {
	ca := mustNewTestCA(t, kmsserviceapi.CAFrontProxy)
	s := &server{cas: map[string]*caMaterial{kmsserviceapi.CAFrontProxy: ca}}
	csrPEM := mustNewCSRPEM(t, csrInput{
		commonName:    "kubernetes-admin",
		organizations: []string{"system:masters"},
	})
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: kmsserviceapi.CAFrontProxy,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}
	_, err = s.SignCSR(context.Background(), wrapperspb.String(payload))
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %v", status.Code(err))
	}
}

func TestUnaryAuthInterceptor_DenyAndAllow(t *testing.T) {
	interceptor := unaryAuthInterceptor(map[string]struct{}{"good-client": {}})

	t.Run("deny", func(t *testing.T) {
		ctx := peer.NewContext(context.Background(), &peer.Peer{
			AuthInfo: credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{mustSelfSignedCert(t, "bad-client")}}},
		})
		called := false
		_, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{}, func(context.Context, interface{}) (interface{}, error) {
			called = true
			return "ok", nil
		})
		if status.Code(err) != codes.PermissionDenied {
			t.Fatalf("expected PermissionDenied, got %v", status.Code(err))
		}
		if called {
			t.Fatalf("handler should not be called on denied client")
		}
	})

	t.Run("allow", func(t *testing.T) {
		ctx := peer.NewContext(context.Background(), &peer.Peer{
			AuthInfo: credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{mustSelfSignedCert(t, "good-client")}}},
		})
		called := false
		resp, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{}, func(context.Context, interface{}) (interface{}, error) {
			called = true
			return "ok", nil
		})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !called || resp != "ok" {
			t.Fatalf("expected handler call and ok response")
		}
	})
}

func mustNewTestCA(t *testing.T, name string) *caMaterial {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate CA key: %v", err)
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create CA cert: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA cert: %v", err)
	}
	return &caMaterial{
		name:    name,
		cert:    cert,
		certPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		key:     key,
		keyPEM:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}),
	}
}

type csrInput struct {
	commonName    string
	organizations []string
	dnsNames      []string
	ipAddresses   []net.IP
}

func mustNewCSRPEM(t *testing.T, in csrInput) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, &x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName:   in.commonName,
			Organization: in.organizations,
		},
		DNSNames:    in.dnsNames,
		IPAddresses: in.ipAddresses,
	}, key)
	if err != nil {
		t.Fatalf("create csr: %v", err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrDER})
}

func mustParseCertPEM(t *testing.T, certPEM []byte) *x509.Certificate {
	t.Helper()
	b, _ := pem.Decode(certPEM)
	if b == nil {
		t.Fatalf("empty cert pem")
	}
	crt, err := x509.ParseCertificate(b.Bytes)
	if err != nil {
		t.Fatalf("parse cert: %v", err)
	}
	return crt
}

func mustSelfSignedCert(t *testing.T, cn string) *x509.Certificate {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	crt, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse cert: %v", err)
	}
	return crt
}
