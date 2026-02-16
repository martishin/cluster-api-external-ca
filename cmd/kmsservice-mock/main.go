package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
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

type caMaterial struct {
	name    string
	cert    *x509.Certificate
	certPEM []byte
	key     *rsa.PrivateKey
	keyPEM  []byte
}

type kmsServiceServer interface {
	GetCA(context.Context, *wrapperspb.StringValue) (*wrapperspb.StringValue, error)
	SignCSR(context.Context, *wrapperspb.StringValue) (*wrapperspb.StringValue, error)
}

type server struct {
	cas map[string]*caMaterial
}

type csrProfile struct {
	commonName    string
	organizations []string
	extKeyUsages  []x509.ExtKeyUsage
	requireSANs   bool
	allowSANs     bool
}

var signingProfilesByCA = map[string]map[string]csrProfile{
	kmsserviceapi.CAKubernetes: {
		"kube-apiserver": {
			commonName:   "kube-apiserver",
			extKeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
			requireSANs:  true,
			allowSANs:    true,
		},
		"kube-apiserver-kubelet-client": {
			commonName:    "kube-apiserver-kubelet-client",
			organizations: []string{"system:masters"},
			extKeyUsages:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:     false,
		},
		"kubernetes-admin": {
			commonName:    "kubernetes-admin",
			organizations: []string{"system:masters"},
			extKeyUsages:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:     false,
		},
		"system:kube-controller-manager": {
			commonName:    "system:kube-controller-manager",
			organizations: []string{"system:kube-controller-manager"},
			extKeyUsages:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:     false,
		},
		"system:kube-scheduler": {
			commonName:    "system:kube-scheduler",
			organizations: []string{"system:kube-scheduler"},
			extKeyUsages:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:     false,
		},
	},
	kmsserviceapi.CAFrontProxy: {
		"front-proxy-client": {
			commonName:   "front-proxy-client",
			extKeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:    false,
		},
	},
	kmsserviceapi.CAEtcd: {
		"kube-apiserver-etcd-client": {
			commonName:    "kube-apiserver-etcd-client",
			organizations: []string{"system:masters"},
			extKeyUsages:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:     false,
		},
		"kube-etcd": {
			commonName:   "kube-etcd",
			extKeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			requireSANs:  true,
			allowSANs:    true,
		},
		"kube-etcd-peer": {
			commonName:   "kube-etcd-peer",
			extKeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			requireSANs:  true,
			allowSANs:    true,
		},
		"kube-etcd-healthcheck-client": {
			commonName:   "kube-etcd-healthcheck-client",
			extKeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
			allowSANs:    false,
		},
	},
}

func main() {
	var (
		addr            string
		stateDir        string
		serverCertPath  string
		serverKeyPath   string
		clientCAPath    string
		allowedClientCN string
	)
	flag.StringVar(&addr, "addr", "127.0.0.1:9443", "gRPC listen address")
	flag.StringVar(&stateDir, "state-dir", "out/kmsservice-mock", "directory for persisted mock CA material")
	flag.StringVar(&serverCertPath, "server-cert", "", "server TLS certificate path")
	flag.StringVar(&serverKeyPath, "server-key", "", "server TLS private key path")
	flag.StringVar(&clientCAPath, "client-ca", "", "trusted client CA certificate path")
	flag.StringVar(&allowedClientCN, "allowed-client-cn", "", "comma-separated allowed mTLS client certificate CNs (optional)")
	flag.Parse()

	if serverCertPath == "" || serverKeyPath == "" || clientCAPath == "" {
		log.Fatal("--server-cert, --server-key and --client-ca are required")
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		log.Fatalf("create state dir: %v", err)
	}

	cas := map[string]*caMaterial{}
	for _, caName := range []string{kmsserviceapi.CAKubernetes, kmsserviceapi.CAFrontProxy, kmsserviceapi.CAEtcd} {
		m, err := loadOrCreateCA(stateDir, caName)
		if err != nil {
			log.Fatalf("init CA %s: %v", caName, err)
		}
		cas[caName] = m
	}

	allowed := map[string]struct{}{}
	for _, cn := range strings.Split(allowedClientCN, ",") {
		cn = strings.TrimSpace(cn)
		if cn == "" {
			continue
		}
		allowed[cn] = struct{}{}
	}

	tlsCfg, err := buildServerTLSConfig(serverCertPath, serverKeyPath, clientCAPath)
	if err != nil {
		log.Fatalf("build tls config: %v", err)
	}
	grpcServer := grpc.NewServer(
		grpc.Creds(credentials.NewTLS(tlsCfg)),
		grpc.UnaryInterceptor(unaryAuthInterceptor(allowed)),
	)

	srv := &server{cas: cas}
	registerKMSService(grpcServer, srv)

	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen on %s: %v", addr, err)
	}
	log.Printf("kmsservice-mock (gRPC+mTLS) listening on %s", addr)
	log.Printf("state dir: %s", stateDir)
	if len(allowed) > 0 {
		log.Printf("allowed client CNs: %v", keys(allowed))
	}
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("grpc server failed: %v", err)
	}
}

func (s *server) GetCA(_ context.Context, req *wrapperspb.StringValue) (*wrapperspb.StringValue, error) {
	caName := strings.TrimSpace(req.GetValue())
	ca, ok := s.cas[caName]
	if !ok {
		return nil, status.Errorf(codes.NotFound, "unknown ca %q", caName)
	}
	return wrapperspb.String(string(ca.certPEM)), nil
}

func (s *server) SignCSR(_ context.Context, req *wrapperspb.StringValue) (*wrapperspb.StringValue, error) {
	in, err := kmsservicegrpc.DecodeSignRequest(req.GetValue())
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid sign payload: %v", err)
	}
	caName := strings.TrimSpace(in.CAName)
	ca, ok := s.cas[caName]
	if !ok {
		return nil, status.Errorf(codes.InvalidArgument, "unknown ca %q", in.CAName)
	}
	csr, err := parseCSRPEM([]byte(in.CSRPEM))
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid csr: %v", err)
	}
	if err := csr.CheckSignature(); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid csr signature: %v", err)
	}
	profile, err := signingProfileFor(caName, csr.Subject.CommonName)
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "unsupported profile: %v", err)
	}
	if err := validateCSRAgainstProfile(csr, profile); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "csr validation failed: %v", err)
	}

	certDER, err := signCSR(ca, csr, profile)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "sign csr failed: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	return wrapperspb.String(string(certPEM)), nil
}

func registerKMSService(grpcServer *grpc.Server, impl kmsServiceServer) {
	grpcServer.RegisterService(&grpc.ServiceDesc{
		ServiceName: kmsservicegrpc.ServiceName,
		HandlerType: (*kmsServiceServer)(nil),
		Methods: []grpc.MethodDesc{
			{
				MethodName: "GetCA",
				Handler: func(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
					in := &wrapperspb.StringValue{}
					if err := dec(in); err != nil {
						return nil, err
					}
					if interceptor == nil {
						return srv.(kmsServiceServer).GetCA(ctx, in)
					}
					info := &grpc.UnaryServerInfo{Server: srv, FullMethod: kmsservicegrpc.GetCAMethod}
					handler := func(ctx context.Context, req interface{}) (interface{}, error) {
						return srv.(kmsServiceServer).GetCA(ctx, req.(*wrapperspb.StringValue))
					}
					return interceptor(ctx, in, info, handler)
				},
			},
			{
				MethodName: "SignCSR",
				Handler: func(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
					in := &wrapperspb.StringValue{}
					if err := dec(in); err != nil {
						return nil, err
					}
					if interceptor == nil {
						return srv.(kmsServiceServer).SignCSR(ctx, in)
					}
					info := &grpc.UnaryServerInfo{Server: srv, FullMethod: kmsservicegrpc.SignMethod}
					handler := func(ctx context.Context, req interface{}) (interface{}, error) {
						return srv.(kmsServiceServer).SignCSR(ctx, req.(*wrapperspb.StringValue))
					}
					return interceptor(ctx, in, info, handler)
				},
			},
		},
	}, impl)
}

func unaryAuthInterceptor(allowed map[string]struct{}) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		if len(allowed) > 0 {
			p, ok := peer.FromContext(ctx)
			if !ok {
				return nil, status.Error(codes.Unauthenticated, "missing peer in context")
			}
			ti, ok := p.AuthInfo.(credentials.TLSInfo)
			if !ok || len(ti.State.PeerCertificates) == 0 {
				return nil, status.Error(codes.Unauthenticated, "missing peer tls certificate")
			}
			cn := ti.State.PeerCertificates[0].Subject.CommonName
			if _, exists := allowed[cn]; !exists {
				return nil, status.Errorf(codes.PermissionDenied, "client CN %q is not allowed", cn)
			}
		}
		_ = info
		return handler(ctx, req)
	}
}

func buildServerTLSConfig(serverCertPath, serverKeyPath, clientCAPath string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(serverCertPath, serverKeyPath)
	if err != nil {
		return nil, fmt.Errorf("load server cert/key: %w", err)
	}
	clientCA, err := os.ReadFile(clientCAPath)
	if err != nil {
		return nil, fmt.Errorf("read client ca: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(clientCA) {
		return nil, fmt.Errorf("parse client ca bundle")
	}
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
		MinVersion:   tls.VersionTLS13,
	}, nil
}

func loadOrCreateCA(stateDir, name string) (*caMaterial, error) {
	prefix := strings.ReplaceAll(name, " ", "-")
	certPath := filepath.Join(stateDir, prefix+".crt")
	keyPath := filepath.Join(stateDir, prefix+".key")

	if certPEM, certErr := os.ReadFile(certPath); certErr == nil {
		if keyPEM, keyErr := os.ReadFile(keyPath); keyErr == nil {
			cert, err := parseCertPEM(certPEM)
			if err != nil {
				return nil, fmt.Errorf("parse existing cert: %w", err)
			}
			key, err := parseRSAKeyPEM(keyPEM)
			if err != nil {
				return nil, fmt.Errorf("parse existing key: %w", err)
			}
			return &caMaterial{name: name, cert: cert, certPEM: certPEM, key: key, keyPEM: keyPEM}, nil
		}
	}

	key, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return nil, fmt.Errorf("generate ca key: %w", err)
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: name},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		MaxPathLen:            1,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, fmt.Errorf("create ca cert: %w", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, fmt.Errorf("parse ca cert: %w", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return nil, fmt.Errorf("write cert: %w", err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write key: %w", err)
	}
	return &caMaterial{name: name, cert: cert, certPEM: certPEM, key: key, keyPEM: keyPEM}, nil
}

func parseCSRPEM(csrPEM []byte) (*x509.CertificateRequest, error) {
	b, _ := pem.Decode(csrPEM)
	if b == nil {
		return nil, fmt.Errorf("empty pem")
	}
	csr, err := x509.ParseCertificateRequest(b.Bytes)
	if err != nil {
		return nil, err
	}
	return csr, nil
}

func parseCertPEM(certPEM []byte) (*x509.Certificate, error) {
	b, _ := pem.Decode(certPEM)
	if b == nil {
		return nil, fmt.Errorf("empty cert pem")
	}
	return x509.ParseCertificate(b.Bytes)
}

func parseRSAKeyPEM(keyPEM []byte) (*rsa.PrivateKey, error) {
	b, _ := pem.Decode(keyPEM)
	if b == nil {
		return nil, fmt.Errorf("empty key pem")
	}
	return x509.ParsePKCS1PrivateKey(b.Bytes)
}

func signCSR(ca *caMaterial, csr *x509.CertificateRequest, profile csrProfile) ([]byte, error) {
	keyUsage := x509.KeyUsageDigitalSignature
	if hasExtKeyUsage(profile.extKeyUsages, x509.ExtKeyUsageServerAuth) {
		keyUsage |= x509.KeyUsageKeyEncipherment
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      csr.Subject,
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(365 * 24 * time.Hour),
		KeyUsage:     keyUsage,
		ExtKeyUsage:  profile.extKeyUsages,
		DNSNames:     csr.DNSNames,
		IPAddresses:  csr.IPAddresses,
	}
	return x509.CreateCertificate(rand.Reader, tmpl, ca.cert, csr.PublicKey, ca.key)
}

func signingProfileFor(caName, commonName string) (csrProfile, error) {
	profilesByCN, ok := signingProfilesByCA[caName]
	if !ok {
		return csrProfile{}, fmt.Errorf("unknown CA %q", caName)
	}
	profile, ok := profilesByCN[commonName]
	if !ok {
		return csrProfile{}, fmt.Errorf("CN %q is not allowed for CA %q", commonName, caName)
	}
	return profile, nil
}

func validateCSRAgainstProfile(csr *x509.CertificateRequest, profile csrProfile) error {
	if csr == nil {
		return fmt.Errorf("csr is nil")
	}
	if csr.Subject.CommonName != profile.commonName {
		return fmt.Errorf("commonName mismatch: got %q want %q", csr.Subject.CommonName, profile.commonName)
	}

	gotOrg := normalizeStrings(csr.Subject.Organization)
	wantOrg := normalizeStrings(profile.organizations)
	if !equalStrings(gotOrg, wantOrg) {
		return fmt.Errorf("organization mismatch: got %v want %v", gotOrg, wantOrg)
	}

	sanCount := len(csr.DNSNames) + len(csr.IPAddresses)
	if profile.requireSANs && sanCount == 0 {
		return fmt.Errorf("at least one SAN is required")
	}
	if !profile.allowSANs && sanCount > 0 {
		return fmt.Errorf("SANs are not allowed for this profile")
	}
	return nil
}

func normalizeStrings(in []string) []string {
	out := make([]string, 0, len(in))
	seen := map[string]struct{}{}
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func hasExtKeyUsage(usages []x509.ExtKeyUsage, needle x509.ExtKeyUsage) bool {
	for _, u := range usages {
		if u == needle {
			return true
		}
	}
	return false
}

func serial() *big.Int {
	limit := new(big.Int).Lsh(big.NewInt(1), 127)
	n, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return big.NewInt(time.Now().UnixNano())
	}
	return n
}

func keys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
