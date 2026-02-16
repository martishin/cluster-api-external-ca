package pki

const (
	// kubeadm kubelet-finalize looks for auth info keyed by system:node:<NodeRegistration.Name>.
	kubeletUserPrefix = "system:node:"
)
