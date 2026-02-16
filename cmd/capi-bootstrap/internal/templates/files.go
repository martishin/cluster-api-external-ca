package templates

import (
	"fmt"

	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/pki"
)

type FileTemplate struct {
	Path      string
	Perm      string
	SecretKey string
	Data      []byte
}

func BuildKubeadmFilesFromSecret(secretName string, a *pki.Artifacts) ([]map[string]any, map[string][]byte, error) {
	if a == nil {
		return nil, nil, fmt.Errorf("artifacts cannot be nil")
	}
	if secretName == "" {
		return nil, nil, fmt.Errorf("secret name cannot be empty")
	}

	entries := []FileTemplate{
		{Path: "/etc/kubernetes/pki/ca.crt", SecretKey: "pki-ca-crt", Data: a.ClusterCA.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/front-proxy-ca.crt", SecretKey: "pki-front-proxy-ca-crt", Data: a.FrontProxy.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/etcd/ca.crt", SecretKey: "pki-etcd-ca-crt", Data: a.EtcdCA.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/sa.pub", SecretKey: "pki-sa-pub", Data: a.SA.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/sa.key", SecretKey: "pki-sa-key", Data: a.SA.KeyPEM, Perm: "0600"},

		{Path: "/etc/kubernetes/pki/apiserver.crt", SecretKey: "pki-apiserver-crt", Data: a.APIServer.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/apiserver.key", SecretKey: "pki-apiserver-key", Data: a.APIServer.KeyPEM, Perm: "0600"},
		{Path: "/etc/kubernetes/pki/apiserver-kubelet-client.crt", SecretKey: "pki-apiserver-kubelet-client-crt", Data: a.APIKubelet.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/apiserver-kubelet-client.key", SecretKey: "pki-apiserver-kubelet-client-key", Data: a.APIKubelet.KeyPEM, Perm: "0600"},
		{Path: "/etc/kubernetes/pki/front-proxy-client.crt", SecretKey: "pki-front-proxy-client-crt", Data: a.FrontClient.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/front-proxy-client.key", SecretKey: "pki-front-proxy-client-key", Data: a.FrontClient.KeyPEM, Perm: "0600"},
		{Path: "/etc/kubernetes/pki/apiserver-etcd-client.crt", SecretKey: "pki-apiserver-etcd-client-crt", Data: a.APIEtcd.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/apiserver-etcd-client.key", SecretKey: "pki-apiserver-etcd-client-key", Data: a.APIEtcd.KeyPEM, Perm: "0600"},

		{Path: "/etc/kubernetes/pki/etcd/server.crt", SecretKey: "pki-etcd-server-crt", Data: a.EtcdServer.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/etcd/server.key", SecretKey: "pki-etcd-server-key", Data: a.EtcdServer.KeyPEM, Perm: "0600"},
		{Path: "/etc/kubernetes/pki/etcd/peer.crt", SecretKey: "pki-etcd-peer-crt", Data: a.EtcdPeer.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/etcd/peer.key", SecretKey: "pki-etcd-peer-key", Data: a.EtcdPeer.KeyPEM, Perm: "0600"},
		{Path: "/etc/kubernetes/pki/etcd/healthcheck-client.crt", SecretKey: "pki-etcd-healthcheck-client-crt", Data: a.EtcdHealth.CertPEM, Perm: "0644"},
		{Path: "/etc/kubernetes/pki/etcd/healthcheck-client.key", SecretKey: "pki-etcd-healthcheck-client-key", Data: a.EtcdHealth.KeyPEM, Perm: "0600"},

		{Path: "/etc/kubernetes/admin.conf", SecretKey: "kubeconfig-admin", Data: a.AdminKubeconfig, Perm: "0600"},
		{Path: "/etc/kubernetes/controller-manager.conf", SecretKey: "kubeconfig-controller-manager", Data: a.ControllerManagerKubeconfig, Perm: "0600"},
		{Path: "/etc/kubernetes/scheduler.conf", SecretKey: "kubeconfig-scheduler", Data: a.SchedulerKubeconfig, Perm: "0600"},
	}

	files := make([]map[string]any, 0, len(entries))
	secretData := make(map[string][]byte, len(entries))
	for _, e := range entries {
		if e.SecretKey == "" {
			return nil, nil, fmt.Errorf("secret key is required for path %q", e.Path)
		}
		if len(e.Data) == 0 {
			return nil, nil, fmt.Errorf("file content is empty for path %q (secret key %q)", e.Path, e.SecretKey)
		}
		secretData[e.SecretKey] = e.Data
		files = append(files, map[string]any{
			"path":        e.Path,
			"owner":       "root:root",
			"permissions": e.Perm,
			"contentFrom": map[string]any{
				"secret": map[string]any{
					"name": secretName,
					"key":  e.SecretKey,
				},
			},
		})
	}
	return files, secretData, nil
}
