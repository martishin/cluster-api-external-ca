package kmsserviceapi

const (
	CAKubernetes = "kubernetes-ca"
	CAFrontProxy = "kubernetes-front-proxy-ca"
	CAEtcd       = "etcd-ca"
)

type SignCSRRequest struct {
	CAName string `json:"caName"`
	CSRPEM string `json:"csrPEM"`
}
