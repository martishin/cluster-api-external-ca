package k8s

import (
	"context"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/retry"
)

var (
	kcpGVR     = schema.GroupVersionResource{Group: "controlplane.cluster.x-k8s.io", Version: "v1beta1", Resource: "kubeadmcontrolplanes"}
	clusterGVR = schema.GroupVersionResource{Group: "cluster.x-k8s.io", Version: "v1beta1", Resource: "clusters"}
)

type Client struct {
	Kube    kubernetes.Interface
	Dynamic dynamic.Interface
}

func New(kubeconfigPath, kubeconfigContext string) (*Client, error) {
	loadingRules := &clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfigPath}
	overrides := &clientcmd.ConfigOverrides{}
	if kubeconfigContext != "" {
		overrides.CurrentContext = kubeconfigContext
	}
	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, overrides).ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("build rest config: %w", err)
	}
	return NewFromRest(cfg)
}

func NewFromRest(cfg *rest.Config) (*Client, error) {
	k, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("create kubernetes client: %w", err)
	}
	d, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("create dynamic client: %w", err)
	}
	return &Client{Kube: k, Dynamic: d}, nil
}

func (c *Client) UpsertSecret(ctx context.Context, namespace string, s *corev1.Secret, dryRun bool) error {
	if s == nil {
		return fmt.Errorf("secret is nil")
	}
	s.Namespace = namespace
	if dryRun {
		return nil
	}
	existing, err := c.Kube.CoreV1().Secrets(namespace).Get(ctx, s.Name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		_, err = c.Kube.CoreV1().Secrets(namespace).Create(ctx, s, metav1.CreateOptions{})
		if err != nil {
			return fmt.Errorf("create secret %s/%s: %w", namespace, s.Name, err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("get secret %s/%s: %w", namespace, s.Name, err)
	}
	existing.Labels = mergeStringMap(existing.Labels, s.Labels)
	existing.Annotations = mergeStringMap(existing.Annotations, s.Annotations)
	existing.Data = s.Data
	existing.StringData = nil
	existing.Type = s.Type
	if _, err := c.Kube.CoreV1().Secrets(namespace).Update(ctx, existing, metav1.UpdateOptions{}); err != nil {
		return fmt.Errorf("update secret %s/%s: %w", namespace, s.Name, err)
	}
	return nil
}

func (c *Client) GetSecret(ctx context.Context, namespace, name string) (*corev1.Secret, error) {
	secret, err := c.Kube.CoreV1().Secrets(namespace).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get secret %s/%s: %w", namespace, name, err)
	}
	return secret, nil
}

func (c *Client) GetClusterServerURL(ctx context.Context, namespace, clusterName string) (string, error) {
	u, err := c.Dynamic.Resource(clusterGVR).Namespace(namespace).Get(ctx, clusterName, metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("get cluster %s/%s: %w", namespace, clusterName, err)
	}
	host, _, _ := unstructured.NestedString(u.Object, "spec", "controlPlaneEndpoint", "host")
	port, _, _ := unstructured.NestedInt64(u.Object, "spec", "controlPlaneEndpoint", "port")
	if host == "" || port == 0 {
		return "", nil
	}
	return fmt.Sprintf("https://%s:%d", host, port), nil
}

func (c *Client) PatchKCPExternalCAAndFiles(ctx context.Context, namespace, kcpName string, files []map[string]any, preKubeadmCommands []string, dryRun bool) error {
	mutate := func(kcp *unstructured.Unstructured) error {
		if err := unstructured.SetNestedField(kcp.Object, true, "spec", "kubeadmConfigSpec", "externalCA"); err != nil {
			return fmt.Errorf("set externalCA: %w", err)
		}

		currentFiles, _, _ := unstructured.NestedSlice(kcp.Object, "spec", "kubeadmConfigSpec", "files")
		mergedFiles := mergeKubeadmFiles(currentFiles, files)
		if err := unstructured.SetNestedSlice(kcp.Object, mergedFiles, "spec", "kubeadmConfigSpec", "files"); err != nil {
			return fmt.Errorf("set files: %w", err)
		}

		currentPreCmd, _, _ := unstructured.NestedStringSlice(kcp.Object, "spec", "kubeadmConfigSpec", "preKubeadmCommands")
		mergedPreCmd := mergeStringSlice(currentPreCmd, preKubeadmCommands)
		if err := unstructured.SetNestedStringSlice(kcp.Object, mergedPreCmd, "spec", "kubeadmConfigSpec", "preKubeadmCommands"); err != nil {
			return fmt.Errorf("set preKubeadmCommands: %w", err)
		}
		return nil
	}

	if dryRun {
		kcp, err := c.Dynamic.Resource(kcpGVR).Namespace(namespace).Get(ctx, kcpName, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("get KCP %s/%s: %w", namespace, kcpName, err)
		}
		if err := mutate(kcp); err != nil {
			return err
		}
		return nil
	}

	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		kcp, getErr := c.Dynamic.Resource(kcpGVR).Namespace(namespace).Get(ctx, kcpName, metav1.GetOptions{})
		if getErr != nil {
			return fmt.Errorf("get KCP %s/%s: %w", namespace, kcpName, getErr)
		}
		if mutateErr := mutate(kcp); mutateErr != nil {
			return mutateErr
		}
		_, updateErr := c.Dynamic.Resource(kcpGVR).Namespace(namespace).Update(ctx, kcp, metav1.UpdateOptions{})
		if updateErr != nil {
			return fmt.Errorf("update KCP %s/%s: %w", namespace, kcpName, updateErr)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return nil
}

func mergeKubeadmFiles(current []any, desired []map[string]any) []any {
	byPath := map[string]map[string]any{}
	order := make([]string, 0, len(current)+len(desired))

	for _, f := range current {
		m, ok := f.(map[string]any)
		if !ok {
			continue
		}
		path, _ := m["path"].(string)
		if path == "" {
			continue
		}
		if _, exists := byPath[path]; !exists {
			order = append(order, path)
		}
		byPath[path] = m
	}
	for _, f := range desired {
		path, _ := f["path"].(string)
		if path == "" {
			continue
		}
		if _, exists := byPath[path]; !exists {
			order = append(order, path)
		}
		byPath[path] = f
	}

	out := make([]any, 0, len(order))
	seen := map[string]struct{}{}
	for _, p := range order {
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, byPath[p])
	}
	return out
}

func mergeStringSlice(current []string, add []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(current)+len(add))
	for _, s := range append(current, add...) {
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

func mergeStringMap(a, b map[string]string) map[string]string {
	if a == nil && b == nil {
		return nil
	}
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}
