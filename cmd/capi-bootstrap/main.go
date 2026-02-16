package main

import (
	"context"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/k8s"
	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/kmsservice"
	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/pki"
	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/templates"
)

const labelClusterName = "cluster.x-k8s.io/cluster-name"

type clusterServerResolver interface {
	GetClusterServerURL(ctx context.Context, namespace, clusterName string) (string, error)
}

func main() {
	var (
		kubeconfigPath       string
		kubeconfigContext    string
		namespace            string
		clusterName          string
		kcpName              string
		mode                 string
		kmsserviceEndpoint   string
		kmsserviceCACert     string
		kmsserviceClientCert string
		kmsserviceClientKey  string
		kmsserviceServerName string
		apiserverSANs        string
		etcdSANs             string
		serverOverride       string
		kubeletNodeName      string
		outputDir            string
		dryRun               bool
		cleanup              bool
	)

	flag.StringVar(&kubeconfigPath, "kubeconfig", "", "Path to management cluster kubeconfig")
	flag.StringVar(&kubeconfigContext, "context", "", "Kubeconfig context")
	flag.StringVar(&namespace, "namespace", "default", "Cluster namespace")
	flag.StringVar(&clusterName, "cluster-name", "", "Cluster name")
	flag.StringVar(&kcpName, "kcp-name", "", "KubeadmControlPlane name")
	flag.StringVar(&mode, "mode", "mock-ca", "Bootstrap mode: mock-ca|kmsservice")
	flag.StringVar(&kmsserviceEndpoint, "kmsservice-endpoint", "", "KMSService gRPC endpoint host:port for --mode kmsservice")
	flag.StringVar(&kmsserviceCACert, "kmsservice-ca-cert", "", "KMSService mTLS CA certificate path for --mode kmsservice")
	flag.StringVar(&kmsserviceClientCert, "kmsservice-client-cert", "", "KMSService mTLS client certificate path for --mode kmsservice")
	flag.StringVar(&kmsserviceClientKey, "kmsservice-client-key", "", "KMSService mTLS client key path for --mode kmsservice")
	flag.StringVar(&kmsserviceServerName, "kmsservice-server-name", "", "Optional TLS server-name override for --mode kmsservice")
	flag.StringVar(&apiserverSANs, "apiserver-san", "", "Extra apiserver SANs, comma-separated")
	flag.StringVar(&etcdSANs, "etcd-san", "", "Extra etcd SANs, comma-separated")
	flag.StringVar(&serverOverride, "server", "", "Override kubeconfig server URL, e.g. https://1.2.3.4:6443")
	flag.StringVar(&kubeletNodeName, "kubelet-node-name", "", "Node name for /etc/kubernetes/kubelet.conf auth user (system:node:<name>)")
	flag.StringVar(&outputDir, "output-dir", "out", "Local output directory for mock-ca material")
	flag.BoolVar(&dryRun, "dry-run", false, "Run without mutating the cluster")
	flag.BoolVar(&cleanup, "cleanup", false, "Delete generated sensitive local artifacts from output-dir after successful bootstrap")
	flag.Parse()

	if kubeconfigPath == "" || clusterName == "" || kcpName == "" {
		fatalf("required flags: --kubeconfig, --cluster-name, --kcp-name")
	}

	if mode != "mock-ca" && mode != "kmsservice" {
		fatalf("unsupported mode %q", mode)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	client, err := k8s.New(kubeconfigPath, kubeconfigContext)
	if err != nil {
		fatalf("create k8s clients: %v", err)
	}

	server, err := resolveKubeconfigServer(ctx, client, namespace, clusterName, serverOverride)
	if err != nil {
		fatalf("resolve kubeconfig server: %v", err)
	}

	clusterOut := filepath.Join(outputDir, clusterName)
	var artifacts *pki.Artifacts
	genOpts := pki.GenerateOptions{
		ClusterName:      clusterName,
		APIServerSANs:    splitCSV(apiserverSANs),
		EtcdSANs:         splitCSV(etcdSANs),
		KubeconfigServer: server,
		KubeletNodeName:  kubeletNodeName,
		OutputDir:        clusterOut,
	}
	switch mode {
	case "mock-ca":
		artifacts, err = pki.GenerateMockArtifacts(genOpts)
	case "kmsservice":
		kmsClient, clientErr := kmsservice.NewClient(kmsservice.Config{
			Endpoint:   kmsserviceEndpoint,
			CACertPath: kmsserviceCACert,
			CertPath:   kmsserviceClientCert,
			KeyPath:    kmsserviceClientKey,
			ServerName: kmsserviceServerName,
		})
		if clientErr != nil {
			fatalf("create kmsservice client: %v", clientErr)
		}
		defer kmsClient.Close()
		artifacts, err = pki.GenerateKMSServiceArtifacts(ctx, genOpts, kmsClient)
	}
	if err != nil {
		fatalf("generate PKI artifacts in mode %q: %v", mode, err)
	}

	if err := reuseServiceAccountKeyIfPresent(ctx, client, namespace, clusterName, artifacts); err != nil {
		fatalf("reuse service-account keypair: %v", err)
	}

	filesSecretName := clusterName + "-external-ca-files"
	files, filesSecretData, err := templates.BuildKubeadmFilesFromSecret(filesSecretName, artifacts)
	if err != nil {
		fatalf("build KCP files: %v", err)
	}

	if err := applySecrets(ctx, client, namespace, clusterName, filesSecretName, filesSecretData, artifacts, dryRun); err != nil {
		fatalf("apply secrets: %v", err)
	}

	preCommands := []string{
		"mkdir -p /etc/kubernetes/pki/etcd",
	}
	if err := client.PatchKCPExternalCAAndFiles(ctx, namespace, kcpName, files, preCommands, dryRun); err != nil {
		fatalf("patch KubeadmControlPlane: %v", err)
	}

	if cleanup {
		if err := pki.CleanupSensitiveOutput(clusterOut); err != nil {
			fatalf("cleanup sensitive output: %v", err)
		}
	}

	fmt.Printf("external-ca bootstrap material generated and applied for cluster %q in namespace %q\n", clusterName, namespace)
	fmt.Printf("bootstrap mode: %s\n", mode)
	if mode == "kmsservice" {
		fmt.Printf("kmsservice endpoint: %s\n", kmsserviceEndpoint)
	}
	fmt.Printf("kubeconfig server used: %s\n", server)
	fmt.Printf("output directory: %s\n", clusterOut)
}

func applySecrets(ctx context.Context, client *k8s.Client, namespace, clusterName, filesSecretName string, filesSecretData map[string][]byte, a *pki.Artifacts, dryRun bool) error {
	labels := map[string]string{labelClusterName: clusterName}

	secrets := []*corev1.Secret{
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-ca", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"tls.crt": a.ClusterCA.CertPEM,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-proxy", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"tls.crt": a.FrontProxy.CertPEM,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-etcd", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"tls.crt": a.EtcdCA.CertPEM,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-apiserver-etcd-client", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"tls.crt": a.APIEtcd.CertPEM,
				"tls.key": a.APIEtcd.KeyPEM,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-sa", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"tls.crt": a.SA.CertPEM,
				"tls.key": a.SA.KeyPEM,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: clusterName + "-kubeconfig", Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data: map[string][]byte{
				"value": a.AdminKubeconfig,
			},
		},
		{
			ObjectMeta: metav1.ObjectMeta{Name: filesSecretName, Labels: labels},
			Type:       corev1.SecretTypeOpaque,
			Data:       filesSecretData,
		},
	}

	for _, s := range secrets {
		if err := client.UpsertSecret(ctx, namespace, s, dryRun); err != nil {
			return err
		}
	}
	return nil
}

func splitCSV(in string) []string {
	parts := strings.Split(in, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func resolveKubeconfigServer(ctx context.Context, resolver clusterServerResolver, namespace, clusterName, override string) (string, error) {
	if s := strings.TrimSpace(override); s != "" {
		return s, nil
	}
	server, err := resolver.GetClusterServerURL(ctx, namespace, clusterName)
	if err != nil {
		return "", err
	}
	server = strings.TrimSpace(server)
	if server == "" {
		return "", fmt.Errorf("cluster %s/%s has empty spec.controlPlaneEndpoint; pass --server explicitly", namespace, clusterName)
	}
	return server, nil
}

func reuseServiceAccountKeyIfPresent(ctx context.Context, client *k8s.Client, namespace, clusterName string, artifacts *pki.Artifacts) error {
	if artifacts == nil {
		return fmt.Errorf("artifacts cannot be nil")
	}
	secretName := clusterName + "-sa"
	existing, err := client.GetSecret(ctx, namespace, secretName)
	if err != nil {
		return err
	}
	if existing == nil {
		return nil
	}

	existingPub := existing.Data["tls.crt"]
	existingKey := existing.Data["tls.key"]
	if len(existingPub) == 0 || len(existingKey) == 0 {
		return nil
	}
	if err := validateServiceAccountKeyPair(existingPub, existingKey); err != nil {
		return fmt.Errorf("existing %s/%s contains invalid tls.crt/tls.key: %w", namespace, secretName, err)
	}

	artifacts.SA.CertPEM = existingPub
	artifacts.SA.KeyPEM = existingKey
	return nil
}

func validateServiceAccountKeyPair(pubPEM, keyPEM []byte) error {
	pub, err := parseRSAPublicKeyPEM(pubPEM)
	if err != nil {
		return fmt.Errorf("parse public key: %w", err)
	}
	key, err := parseRSAPrivateKeyPEM(keyPEM)
	if err != nil {
		return fmt.Errorf("parse private key: %w", err)
	}
	if pub.E != key.PublicKey.E || pub.N.Cmp(key.PublicKey.N) != 0 {
		return fmt.Errorf("public/private key mismatch")
	}
	return nil
}

func parseRSAPublicKeyPEM(pubPEM []byte) (*rsa.PublicKey, error) {
	block, _ := pem.Decode(pubPEM)
	if block == nil {
		return nil, fmt.Errorf("empty pem block")
	}
	pubAny, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	pub, ok := pubAny.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("public key is not RSA")
	}
	return pub, nil
}

func parseRSAPrivateKeyPEM(keyPEM []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, fmt.Errorf("empty pem block")
	}
	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}
	keyAny, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := keyAny.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("private key is not RSA")
	}
	return key, nil
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
