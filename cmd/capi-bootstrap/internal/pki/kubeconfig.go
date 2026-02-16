package pki

import (
	"fmt"

	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	clientcmdlatest "k8s.io/client-go/tools/clientcmd/api/latest"
)

func BuildKubeconfig(server string, caPEM []byte, user string, clientCert []byte, clientKey []byte) ([]byte, error) {
	if server == "" {
		return nil, fmt.Errorf("server cannot be empty")
	}
	cfg := clientcmdapi.NewConfig()
	cfg.Clusters["default"] = &clientcmdapi.Cluster{
		Server:                   server,
		CertificateAuthorityData: caPEM,
	}
	cfg.AuthInfos[user] = &clientcmdapi.AuthInfo{
		ClientCertificateData: clientCert,
		ClientKeyData:         clientKey,
	}
	cfg.Contexts["default"] = &clientcmdapi.Context{
		Cluster:  "default",
		AuthInfo: user,
	}
	cfg.CurrentContext = "default"

	out, err := clientcmd.Write(*cfg)
	if err != nil {
		return nil, fmt.Errorf("serialize kubeconfig: %w", err)
	}
	if _, _, err := clientcmdlatest.Codec.Decode(out, nil, nil); err != nil {
		return nil, fmt.Errorf("generated kubeconfig is invalid: %w", err)
	}
	return out, nil
}
