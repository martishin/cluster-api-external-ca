package templates

import (
	"strings"
	"testing"

	"github.com/martishin/cluster-api-external-ca/cmd/capi-bootstrap/internal/pki"
)

func testArtifacts() *pki.Artifacts {
	b := []byte("x")
	return &pki.Artifacts{
		ClusterCA:                   pki.KeyPair{CertPEM: b},
		FrontProxy:                  pki.KeyPair{CertPEM: b},
		EtcdCA:                      pki.KeyPair{CertPEM: b},
		SA:                          pki.KeyPair{CertPEM: b, KeyPEM: b},
		APIServer:                   pki.KeyPair{CertPEM: b, KeyPEM: b},
		APIKubelet:                  pki.KeyPair{CertPEM: b, KeyPEM: b},
		FrontClient:                 pki.KeyPair{CertPEM: b, KeyPEM: b},
		APIEtcd:                     pki.KeyPair{CertPEM: b, KeyPEM: b},
		EtcdServer:                  pki.KeyPair{CertPEM: b, KeyPEM: b},
		EtcdPeer:                    pki.KeyPair{CertPEM: b, KeyPEM: b},
		EtcdHealth:                  pki.KeyPair{CertPEM: b, KeyPEM: b},
		AdminKubeconfig:             b,
		ControllerManagerKubeconfig: b,
		SchedulerKubeconfig:         b,
	}
}

func TestBuildKubeadmFilesFromSecret_Success(t *testing.T) {
	files, secretData, err := BuildKubeadmFilesFromSecret("my-secret", testArtifacts())
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(files) == 0 || len(secretData) == 0 {
		t.Fatalf("expected non-empty output")
	}
	if _, ok := secretData["pki-ca-crt"]; !ok {
		t.Fatalf("expected pki-ca-crt in secret data")
	}
}

func TestBuildKubeadmFilesFromSecret_FailsOnEmptyData(t *testing.T) {
	a := testArtifacts()
	a.ClusterCA.CertPEM = nil
	_, _, err := BuildKubeadmFilesFromSecret("my-secret", a)
	if err == nil {
		t.Fatalf("expected error")
	}
	if !strings.Contains(err.Error(), "/etc/kubernetes/pki/ca.crt") {
		t.Fatalf("unexpected error: %v", err)
	}
}
