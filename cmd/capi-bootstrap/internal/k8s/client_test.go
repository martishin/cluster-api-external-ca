package k8s

import "testing"

func TestMergeStringSlice_DedupTrim(t *testing.T) {
	got := mergeStringSlice([]string{" a ", "b", ""}, []string{"b", "c", "  "})
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("unexpected len: got=%d want=%d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("unexpected item[%d]: got=%q want=%q", i, got[i], want[i])
		}
	}
}

func TestMergeKubeadmFiles_DesiredOverridesByPath(t *testing.T) {
	current := []any{
		map[string]any{"path": "/b", "permissions": "0644"},
		map[string]any{"path": "/a", "permissions": "0644"},
	}
	desired := []map[string]any{
		{"path": "/a", "permissions": "0600"},
		{"path": "/c", "permissions": "0600"},
	}
	out := mergeKubeadmFiles(current, desired)
	if len(out) != 3 {
		t.Fatalf("unexpected len: %d", len(out))
	}
	m0 := out[0].(map[string]any)
	m1 := out[1].(map[string]any)
	m2 := out[2].(map[string]any)
	if m0["path"] != "/b" || m1["path"] != "/a" || m2["path"] != "/c" {
		t.Fatalf("unexpected order/paths: %#v", out)
	}
	if m1["permissions"] != "0600" {
		t.Fatalf("expected desired /a to override current")
	}
}
