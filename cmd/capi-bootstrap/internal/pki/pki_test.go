package pki

import (
	"os"
	"path/filepath"
	"testing"

	"k8s.io/client-go/tools/clientcmd"
)

func TestCleanupSensitiveOutput_RemovesSensitiveArtifacts(t *testing.T) {
	dir := t.TempDir()
	mustWrite := func(name string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	mustWrite("cluster-ca.key")
	mustWrite("front-proxy-ca.key")
	mustWrite("etcd-ca.key")
	mustWrite("apiserver.key")
	mustWrite("admin.conf")
	mustWrite("kubelet.conf")
	mustWrite("super-admin.conf")
	mustWrite("controller-manager.conf")
	mustWrite("scheduler.conf")
	mustWrite("kubeconfig")
	mustWrite("cluster-ca.crt")
	mustWrite("notes.txt")

	if err := CleanupSensitiveOutput(dir); err != nil {
		t.Fatalf("cleanup failed: %v", err)
	}

	removed := []string{"cluster-ca.key", "front-proxy-ca.key", "etcd-ca.key", "apiserver.key", "admin.conf", "kubelet.conf", "super-admin.conf", "controller-manager.conf", "scheduler.conf", "kubeconfig"}
	for _, name := range removed {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("expected %s to be removed", name)
		}
	}

	kept := []string{"cluster-ca.crt", "notes.txt"}
	for _, name := range kept {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatalf("expected %s to stay: %v", name, err)
		}
	}
}

func TestCleanupSensitiveOutput_MissingDir(t *testing.T) {
	if err := CleanupSensitiveOutput(filepath.Join(t.TempDir(), "missing")); err != nil {
		t.Fatalf("expected nil error on missing dir, got %v", err)
	}
}

func TestBuildKubeconfig_KubeletUserFromNodeName(t *testing.T) {
	kubeletUser := kubeletAuthInfoUser("node-1")
	cfgBytes, err := BuildKubeconfig(
		"https://127.0.0.1:6443",
		[]byte("ca"),
		kubeletUser,
		[]byte("cert"),
		[]byte("key"),
	)
	if err != nil {
		t.Fatalf("build kubeconfig: %v", err)
	}

	cfg, err := clientcmd.Load(cfgBytes)
	if err != nil {
		t.Fatalf("load kubeconfig: %v", err)
	}

	if _, ok := cfg.AuthInfos[kubeletUser]; !ok {
		t.Fatalf("expected auth info key %q", kubeletUser)
	}
	ctx, ok := cfg.Contexts["default"]
	if !ok {
		t.Fatalf("expected default context")
	}
	if ctx.AuthInfo != kubeletUser {
		t.Fatalf("expected default context auth info %q, got %q", kubeletUser, ctx.AuthInfo)
	}
}

func TestKubeletAuthInfoUser_DefaultsToAdminWhenNodeNameEmpty(t *testing.T) {
	if got := kubeletAuthInfoUser(""); got != "kubernetes-admin" {
		t.Fatalf("expected kubernetes-admin fallback, got %q", got)
	}
}
