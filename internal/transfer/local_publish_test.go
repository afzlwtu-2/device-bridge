package transfer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMoveLocalNoReplacePreservesBothEntries(t *testing.T) {
	parent := t.TempDir()
	source, destination := filepath.Join(parent, "trashed"), filepath.Join(parent, "restored")
	if err := os.WriteFile(source, []byte("recover me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := MoveLocalNoReplace(source, destination); err == nil {
		t.Fatal("the existing destination was accepted")
	}
	for path, want := range map[string]string{source: "recover me", destination: "keep me"} {
		if got, err := os.ReadFile(path); err != nil || string(got) != want {
			t.Fatalf("entry after rejected restore: %q, %v", got, err)
		}
	}
	if err := os.Remove(destination); err != nil {
		t.Fatal(err)
	}
	if err := MoveLocalNoReplace(source, destination); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(destination); err != nil || string(got) != "recover me" {
		t.Fatalf("restored entry: %q, %v", got, err)
	}
}
