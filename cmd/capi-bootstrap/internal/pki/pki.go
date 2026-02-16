package pki

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type KeyPair struct {
	CertPEM []byte
	KeyPEM  []byte
}

type Artifacts struct {
	ClusterCA   KeyPair
	FrontProxy  KeyPair
	EtcdCA      KeyPair
	SA          KeyPair
	APIServer   KeyPair
	APIKubelet  KeyPair
	FrontClient KeyPair
	APIEtcd     KeyPair
	EtcdServer  KeyPair
	EtcdPeer    KeyPair
	EtcdHealth  KeyPair

	AdminKubeconfig             []byte
	ControllerManagerKubeconfig []byte
	SchedulerKubeconfig         []byte
}

type GenerateOptions struct {
	ClusterName      string
	APIServerSANs    []string
	EtcdSANs         []string
	KubeconfigServer string
	OutputDir        string
}

func GenerateMockArtifacts(opts GenerateOptions) (*Artifacts, error) {
	if opts.ClusterName == "" {
		return nil, fmt.Errorf("cluster-name is required")
	}
	if opts.OutputDir == "" {
		return nil, fmt.Errorf("output-dir is required")
	}
	if err := os.MkdirAll(opts.OutputDir, 0o755); err != nil {
		return nil, fmt.Errorf("create output dir: %w", err)
	}

	clusterCA, clusterCert, err := newCA("kubernetes-ca")
	if err != nil {
		return nil, err
	}
	frontCA, frontCert, err := newCA("kubernetes-front-proxy-ca")
	if err != nil {
		return nil, err
	}
	etcdCA, etcdCert, err := newCA("etcd-ca")
	if err != nil {
		return nil, err
	}

	if err := writePEMs(opts.OutputDir, map[string]KeyPair{
		"cluster-ca":     clusterCA,
		"front-proxy-ca": frontCA,
		"etcd-ca":        etcdCA,
	}); err != nil {
		return nil, err
	}

	sa, err := newRSAKeypair()
	if err != nil {
		return nil, err
	}

	apiserver, err := newLeaf(clusterCert, clusterCA, leafSpec{
		CommonName: "kube-apiserver",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		SANs:       append(defaultAPIServerSANs(), opts.APIServerSANs...),
	})
	if err != nil {
		return nil, err
	}
	apiKubelet, err := newLeaf(clusterCert, clusterCA, leafSpec{
		CommonName: "kube-apiserver-kubelet-client",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	frontClient, err := newLeaf(frontCert, frontCA, leafSpec{
		CommonName: "front-proxy-client",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	apiEtcd, err := newLeaf(etcdCert, etcdCA, leafSpec{
		CommonName: "kube-apiserver-etcd-client",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}

	etcdSans := append(defaultEtcdSANs(), opts.EtcdSANs...)
	etcdServer, err := newLeaf(etcdCert, etcdCA, leafSpec{
		CommonName: "kube-etcd",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		SANs:       etcdSans,
	})
	if err != nil {
		return nil, err
	}
	etcdPeer, err := newLeaf(etcdCert, etcdCA, leafSpec{
		CommonName: "kube-etcd-peer",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		SANs:       etcdSans,
	})
	if err != nil {
		return nil, err
	}
	etcdHealth, err := newLeaf(etcdCert, etcdCA, leafSpec{
		CommonName: "kube-etcd-healthcheck-client",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}

	admin, err := newLeaf(clusterCert, clusterCA, leafSpec{
		CommonName: "kubernetes-admin",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	controllerManager, err := newLeaf(clusterCert, clusterCA, leafSpec{
		CommonName: "system:kube-controller-manager",
		Org:        []string{"system:kube-controller-manager"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	scheduler, err := newLeaf(clusterCert, clusterCA, leafSpec{
		CommonName: "system:kube-scheduler",
		Org:        []string{"system:kube-scheduler"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}

	server := opts.KubeconfigServer
	if server == "" {
		server = "https://127.0.0.1:6443"
	}

	adminCfg, err := BuildKubeconfig(server, clusterCA.CertPEM, "kubernetes-admin", admin.CertPEM, admin.KeyPEM)
	if err != nil {
		return nil, err
	}
	cmCfg, err := BuildKubeconfig("https://127.0.0.1:6443", clusterCA.CertPEM, "system:kube-controller-manager", controllerManager.CertPEM, controllerManager.KeyPEM)
	if err != nil {
		return nil, err
	}
	schedulerCfg, err := BuildKubeconfig("https://127.0.0.1:6443", clusterCA.CertPEM, "system:kube-scheduler", scheduler.CertPEM, scheduler.KeyPEM)
	if err != nil {
		return nil, err
	}

	return &Artifacts{
		ClusterCA:                   KeyPair{CertPEM: clusterCA.CertPEM},
		FrontProxy:                  KeyPair{CertPEM: frontCA.CertPEM},
		EtcdCA:                      KeyPair{CertPEM: etcdCA.CertPEM},
		SA:                          sa,
		APIServer:                   apiserver,
		APIKubelet:                  apiKubelet,
		FrontClient:                 frontClient,
		APIEtcd:                     apiEtcd,
		EtcdServer:                  etcdServer,
		EtcdPeer:                    etcdPeer,
		EtcdHealth:                  etcdHealth,
		AdminKubeconfig:             adminCfg,
		ControllerManagerKubeconfig: cmCfg,
		SchedulerKubeconfig:         schedulerCfg,
	}, nil
}

func CleanupSensitiveOutput(outputDir string) error {
	entries, err := os.ReadDir(outputDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read output dir %q: %w", outputDir, err)
	}

	var errs []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !isSensitiveOutputName(name) {
			continue
		}
		path := filepath.Join(outputDir, name)
		if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
			errs = append(errs, fmt.Sprintf("%s: %v", path, removeErr))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("cleanup sensitive output failed: %s", strings.Join(errs, "; "))
	}
	return nil
}

func isSensitiveOutputName(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	if strings.HasSuffix(name, ".key") {
		return true
	}
	if strings.HasPrefix(name, "kubeconfig") {
		return true
	}
	switch name {
	case "admin.conf", "controller-manager.conf", "scheduler.conf", "bootstrap-admin.conf":
		return true
	default:
		return false
	}
}

type leafSpec struct {
	CommonName string
	Org        []string
	SANs       []string
	Usages     []x509.ExtKeyUsage
}

func newCA(cn string) (KeyPair, *x509.Certificate, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 4096)
	if err != nil {
		return KeyPair{}, nil, fmt.Errorf("generate ca key: %w", err)
	}

	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject: pkix.Name{
			CommonName: cn,
		},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		MaxPathLen:            1,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return KeyPair{}, nil, fmt.Errorf("create ca cert: %w", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return KeyPair{}, nil, fmt.Errorf("parse ca cert: %w", err)
	}

	pair := KeyPair{
		CertPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)}),
	}
	return pair, cert, nil
}

func newLeaf(parentCert *x509.Certificate, parentKey KeyPair, spec leafSpec) (KeyPair, error) {
	if parentCert == nil {
		return KeyPair{}, fmt.Errorf("parent certificate is nil")
	}
	parentPK, err := decodeRSA(parentKey.KeyPEM)
	if err != nil {
		return KeyPair{}, err
	}
	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return KeyPair{}, fmt.Errorf("generate leaf key: %w", err)
	}

	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject: pkix.Name{
			CommonName:   spec.CommonName,
			Organization: spec.Org,
		},
		NotBefore:   now.Add(-time.Hour),
		NotAfter:    now.Add(365 * 24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: spec.Usages,
		IPAddresses: []net.IP{},
		DNSNames:    []string{},
	}
	for _, san := range uniq(spec.SANs) {
		san = strings.TrimSpace(san)
		if san == "" {
			continue
		}
		if ip := net.ParseIP(san); ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
			continue
		}
		tmpl.DNSNames = append(tmpl.DNSNames, san)
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, parentCert, &leafKey.PublicKey, parentPK)
	if err != nil {
		return KeyPair{}, fmt.Errorf("create leaf cert %q: %w", spec.CommonName, err)
	}

	return KeyPair{
		CertPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(leafKey)}),
	}, nil
}

func newRSAKeypair() (KeyPair, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return KeyPair{}, fmt.Errorf("generate rsa key: %w", err)
	}
	pubBytes, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		return KeyPair{}, fmt.Errorf("marshal public key: %w", err)
	}
	return KeyPair{
		CertPEM: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubBytes}),
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)}),
	}, nil
}

func decodeRSA(keyPEM []byte) (*rsa.PrivateKey, error) {
	b, _ := pem.Decode(keyPEM)
	if b == nil {
		return nil, fmt.Errorf("decode rsa key pem: empty block")
	}
	k, err := x509.ParsePKCS1PrivateKey(b.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse rsa key: %w", err)
	}
	return k, nil
}

func defaultAPIServerSANs() []string {
	return []string{
		"kubernetes",
		"kubernetes.default",
		"kubernetes.default.svc",
		"kubernetes.default.svc.cluster.local",
		"localhost",
		"127.0.0.1",
		"::1",
	}
}

func defaultEtcdSANs() []string {
	return []string{
		"localhost",
		"127.0.0.1",
		"::1",
	}
}

func writePEMs(dir string, entries map[string]KeyPair) error {
	for name, pair := range entries {
		if len(pair.CertPEM) > 0 {
			if err := os.WriteFile(filepath.Join(dir, name+".crt"), pair.CertPEM, 0o644); err != nil {
				return fmt.Errorf("write %s cert: %w", name, err)
			}
		}
		if len(pair.KeyPEM) > 0 {
			if err := os.WriteFile(filepath.Join(dir, name+".key"), pair.KeyPEM, 0o600); err != nil {
				return fmt.Errorf("write %s key: %w", name, err)
			}
		}
	}
	return nil
}

func serial() *big.Int {
	limit := new(big.Int).Lsh(big.NewInt(1), 127)
	n, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return big.NewInt(time.Now().UnixNano())
	}
	return n
}

func uniq(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
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
	return out
}
