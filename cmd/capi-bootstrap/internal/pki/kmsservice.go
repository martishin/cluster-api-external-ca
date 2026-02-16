package pki

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"

	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/kmsservice"
	"github.com/martishin/cluster-api-external-ca/internal/kmsserviceapi"
)

func GenerateKMSServiceArtifacts(ctx context.Context, opts GenerateOptions, kmsClient *kmsservice.Client) (*Artifacts, error) {
	if opts.ClusterName == "" {
		return nil, fmt.Errorf("cluster-name is required")
	}
	if opts.OutputDir == "" {
		return nil, fmt.Errorf("output-dir is required")
	}
	if kmsClient == nil {
		return nil, fmt.Errorf("kmsservice client is required")
	}
	if err := os.MkdirAll(opts.OutputDir, 0o755); err != nil {
		return nil, fmt.Errorf("create output dir: %w", err)
	}

	clusterCAPEM, err := kmsClient.GetCA(ctx, kmsserviceapi.CAKubernetes)
	if err != nil {
		return nil, fmt.Errorf("fetch kubernetes ca: %w", err)
	}
	clusterCACert, err := certFromPEM(clusterCAPEM)
	if err != nil {
		return nil, fmt.Errorf("parse kubernetes ca: %w", err)
	}
	frontCAPEM, err := kmsClient.GetCA(ctx, kmsserviceapi.CAFrontProxy)
	if err != nil {
		return nil, fmt.Errorf("fetch front-proxy ca: %w", err)
	}
	frontCACert, err := certFromPEM(frontCAPEM)
	if err != nil {
		return nil, fmt.Errorf("parse front-proxy ca: %w", err)
	}
	etcdCAPEM, err := kmsClient.GetCA(ctx, kmsserviceapi.CAEtcd)
	if err != nil {
		return nil, fmt.Errorf("fetch etcd ca: %w", err)
	}
	etcdCACert, err := certFromPEM(etcdCAPEM)
	if err != nil {
		return nil, fmt.Errorf("parse etcd ca: %w", err)
	}

	if err := writePEMs(opts.OutputDir, map[string]KeyPair{
		"cluster-ca":     {CertPEM: clusterCAPEM},
		"front-proxy-ca": {CertPEM: frontCAPEM},
		"etcd-ca":        {CertPEM: etcdCAPEM},
	}); err != nil {
		return nil, err
	}

	sa, err := newRSAKeypair()
	if err != nil {
		return nil, err
	}

	apiserver, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
		CommonName: "kube-apiserver",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		SANs:       append(defaultAPIServerSANs(), opts.APIServerSANs...),
	})
	if err != nil {
		return nil, err
	}
	apiKubelet, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
		CommonName: "kube-apiserver-kubelet-client",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	frontClient, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAFrontProxy, frontCACert, leafSpec{
		CommonName: "front-proxy-client",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	apiEtcd, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAEtcd, etcdCACert, leafSpec{
		CommonName: "kube-apiserver-etcd-client",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}

	etcdSans := append(defaultEtcdSANs(), opts.EtcdSANs...)
	etcdServer, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAEtcd, etcdCACert, leafSpec{
		CommonName: "kube-etcd",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		SANs:       etcdSans,
	})
	if err != nil {
		return nil, err
	}
	etcdPeer, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAEtcd, etcdCACert, leafSpec{
		CommonName: "kube-etcd-peer",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		SANs:       etcdSans,
	})
	if err != nil {
		return nil, err
	}
	etcdHealth, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAEtcd, etcdCACert, leafSpec{
		CommonName: "kube-etcd-healthcheck-client",
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}

	admin, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
		CommonName: "kubernetes-admin",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	superAdmin, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
		CommonName: "kubernetes-super-admin",
		Org:        []string{"system:masters"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	controllerManager, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
		CommonName: "system:kube-controller-manager",
		Org:        []string{"system:kube-controller-manager"},
		Usages:     []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	})
	if err != nil {
		return nil, err
	}
	scheduler, err := newLeafViaKMSService(ctx, kmsClient, kmsserviceapi.CAKubernetes, clusterCACert, leafSpec{
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
	kubeletUser := kubeletAuthInfoUser(opts.KubeletNodeName)

	adminCfg, err := BuildKubeconfig(server, clusterCAPEM, "kubernetes-admin", admin.CertPEM, admin.KeyPEM)
	if err != nil {
		return nil, err
	}
	kubeletCfg, err := BuildKubeconfig(server, clusterCAPEM, kubeletUser, admin.CertPEM, admin.KeyPEM)
	if err != nil {
		return nil, err
	}
	superAdminCfg, err := BuildKubeconfig(server, clusterCAPEM, "kubernetes-super-admin", superAdmin.CertPEM, superAdmin.KeyPEM)
	if err != nil {
		return nil, err
	}
	cmCfg, err := BuildKubeconfig("https://127.0.0.1:6443", clusterCAPEM, "system:kube-controller-manager", controllerManager.CertPEM, controllerManager.KeyPEM)
	if err != nil {
		return nil, err
	}
	schedulerCfg, err := BuildKubeconfig("https://127.0.0.1:6443", clusterCAPEM, "system:kube-scheduler", scheduler.CertPEM, scheduler.KeyPEM)
	if err != nil {
		return nil, err
	}

	return &Artifacts{
		ClusterCA:                   KeyPair{CertPEM: clusterCAPEM},
		FrontProxy:                  KeyPair{CertPEM: frontCAPEM},
		EtcdCA:                      KeyPair{CertPEM: etcdCAPEM},
		SA:                          sa,
		APIServer:                   apiserver,
		APIKubelet:                  apiKubelet,
		FrontClient:                 frontClient,
		APIEtcd:                     apiEtcd,
		EtcdServer:                  etcdServer,
		EtcdPeer:                    etcdPeer,
		EtcdHealth:                  etcdHealth,
		AdminKubeconfig:             adminCfg,
		KubeletKubeconfig:           kubeletCfg,
		SuperAdminKubeconfig:        superAdminCfg,
		ControllerManagerKubeconfig: cmCfg,
		SchedulerKubeconfig:         schedulerCfg,
	}, nil
}

func newLeafViaKMSService(ctx context.Context, kmsClient *kmsservice.Client, caName string, caCert *x509.Certificate, spec leafSpec) (KeyPair, error) {
	if caCert == nil {
		return KeyPair{}, fmt.Errorf("ca certificate cannot be nil for %q", caName)
	}
	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return KeyPair{}, fmt.Errorf("generate leaf key: %w", err)
	}

	csrTemplate := &x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName:   spec.CommonName,
			Organization: spec.Org,
		},
		DNSNames:    []string{},
		IPAddresses: []net.IP{},
	}
	for _, san := range uniq(spec.SANs) {
		san = strings.TrimSpace(san)
		if san == "" {
			continue
		}
		if ip := net.ParseIP(san); ip != nil {
			csrTemplate.IPAddresses = append(csrTemplate.IPAddresses, ip)
			continue
		}
		csrTemplate.DNSNames = append(csrTemplate.DNSNames, san)
	}
	csrDER, err := x509.CreateCertificateRequest(rand.Reader, csrTemplate, leafKey)
	if err != nil {
		return KeyPair{}, fmt.Errorf("create csr for %q: %w", spec.CommonName, err)
	}
	csrPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE REQUEST", Bytes: csrDER})

	certPEM, err := kmsClient.SignCSR(ctx, caName, csrPEM)
	if err != nil {
		return KeyPair{}, fmt.Errorf("remote sign csr for %q: %w", spec.CommonName, err)
	}
	cert, err := certFromPEM(certPEM)
	if err != nil {
		return KeyPair{}, fmt.Errorf("parse signed cert for %q: %w", spec.CommonName, err)
	}
	if err := validateSignedLeaf(caName, caCert, cert, spec); err != nil {
		return KeyPair{}, fmt.Errorf("validate signed cert for %q: %w", spec.CommonName, err)
	}
	if err := validateLeafPrivateKeyMatchesCert(leafKey, cert); err != nil {
		return KeyPair{}, fmt.Errorf("validate private key for %q: %w", spec.CommonName, err)
	}

	return KeyPair{
		CertPEM: certPEM,
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(leafKey)}),
	}, nil
}

func certFromPEM(certPEM []byte) (*x509.Certificate, error) {
	b, _ := pem.Decode(certPEM)
	if b == nil {
		return nil, fmt.Errorf("decode cert pem: empty block")
	}
	crt, err := x509.ParseCertificate(b.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse cert: %w", err)
	}
	return crt, nil
}

func validateSignedLeaf(caName string, caCert, cert *x509.Certificate, spec leafSpec) error {
	if cert == nil {
		return fmt.Errorf("cert is nil")
	}
	if caCert == nil {
		return fmt.Errorf("ca cert is nil")
	}
	if cert.IsCA {
		return fmt.Errorf("signed certificate must be leaf, got CA=true")
	}
	if err := cert.CheckSignatureFrom(caCert); err != nil {
		return fmt.Errorf("certificate is not signed by expected ca %q: %w", caName, err)
	}
	if cert.Subject.CommonName != spec.CommonName {
		return fmt.Errorf("commonName mismatch: got %q want %q", cert.Subject.CommonName, spec.CommonName)
	}
	if !equalStringSet(cert.Subject.Organization, spec.Org) {
		return fmt.Errorf("organization mismatch: got %v want %v", normalizeStringSet(cert.Subject.Organization), normalizeStringSet(spec.Org))
	}

	wantDNS, wantIPs := splitSANs(spec.SANs)
	if !equalStringSet(cert.DNSNames, wantDNS) {
		return fmt.Errorf("dns SAN mismatch: got %v want %v", normalizeStringSet(cert.DNSNames), normalizeStringSet(wantDNS))
	}
	if !equalStringSet(ipStrings(cert.IPAddresses), ipStrings(wantIPs)) {
		return fmt.Errorf("ip SAN mismatch: got %v want %v", normalizeStringSet(ipStrings(cert.IPAddresses)), normalizeStringSet(ipStrings(wantIPs)))
	}
	if !equalExtKeyUsageSet(cert.ExtKeyUsage, spec.Usages) {
		return fmt.Errorf("extended key usage mismatch: got %v want %v", normalizeExtKeyUsages(cert.ExtKeyUsage), normalizeExtKeyUsages(spec.Usages))
	}
	return nil
}

func validateLeafPrivateKeyMatchesCert(leafKey *rsa.PrivateKey, cert *x509.Certificate) error {
	if leafKey == nil {
		return fmt.Errorf("leaf key is nil")
	}
	if cert == nil {
		return fmt.Errorf("cert is nil")
	}
	certPK, ok := cert.PublicKey.(*rsa.PublicKey)
	if !ok {
		return fmt.Errorf("certificate public key is not RSA")
	}
	if certPK.E != leafKey.PublicKey.E || certPK.N.Cmp(leafKey.PublicKey.N) != 0 {
		return fmt.Errorf("certificate public key does not match generated private key")
	}
	return nil
}

func splitSANs(sans []string) ([]string, []net.IP) {
	outDNS := []string{}
	outIPs := []net.IP{}
	for _, san := range uniq(sans) {
		san = strings.TrimSpace(san)
		if san == "" {
			continue
		}
		if ip := net.ParseIP(san); ip != nil {
			outIPs = append(outIPs, ip)
			continue
		}
		outDNS = append(outDNS, san)
	}
	return outDNS, outIPs
}

func ipStrings(in []net.IP) []string {
	out := make([]string, 0, len(in))
	for _, ip := range in {
		if ip == nil {
			continue
		}
		out = append(out, ip.String())
	}
	return out
}

func equalStringSet(a, b []string) bool {
	na := normalizeStringSet(a)
	nb := normalizeStringSet(b)
	if len(na) != len(nb) {
		return false
	}
	for i := range na {
		if na[i] != nb[i] {
			return false
		}
	}
	return true
}

func normalizeStringSet(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
	for _, v := range in {
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	sort.Strings(out)
	return out
}

func equalExtKeyUsageSet(a, b []x509.ExtKeyUsage) bool {
	na := normalizeExtKeyUsages(a)
	nb := normalizeExtKeyUsages(b)
	if len(na) != len(nb) {
		return false
	}
	for i := range na {
		if na[i] != nb[i] {
			return false
		}
	}
	return true
}

func normalizeExtKeyUsages(in []x509.ExtKeyUsage) []x509.ExtKeyUsage {
	seen := map[x509.ExtKeyUsage]struct{}{}
	out := make([]x509.ExtKeyUsage, 0, len(in))
	for _, v := range in {
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
