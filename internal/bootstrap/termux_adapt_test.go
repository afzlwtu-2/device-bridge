package bootstrap

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestTermuxAdaptLDPreloadAndPathTranslation(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("host Linux cc required for LD_PRELOAD test")
	}
	cc, err := exec.LookPath("cc")
	if err != nil {
		cc, err = exec.LookPath("gcc")
		if err != nil {
			t.Skip("no C compiler available")
		}
	}

	tmp := t.TempDir()
	cSrc := filepath.Join("termux_adapt", "db_termux_adapt.c")
	unitSrc := filepath.Join(tmp, "unit.c")
	unitBin := filepath.Join(tmp, "unit")
	unitCode := `
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

const char *db_adapt_translate_path(const char *path, char *buf, size_t buf_sz, bool for_exec);

int main(void) {
    char buf[PATH_MAX];
    setenv("PREFIX", "/data/user/0/org.example.customapp/files/terminal/files/usr", 1);
    setenv("HOME", "/data/user/0/org.example.customapp/files/terminal/files/home", 1);
    setenv("TERMUX_CACHE_DIR", "/data/user/0/org.example.customapp/files/terminal/cache", 1);

    const char *p1 = db_adapt_translate_path("/data/data/com.termux/files/usr/etc/apt/sources.list", buf, sizeof(buf), false);
    assert(strcmp(p1, "/data/user/0/org.example.customapp/files/terminal/files/usr/etc/apt/sources.list") == 0);

    const char *p2 = db_adapt_translate_path("/data/user/0/com.termux/files/home/.bashrc", buf, sizeof(buf), false);
    assert(strcmp(p2, "/data/user/0/org.example.customapp/files/terminal/files/home/.bashrc") == 0);

    const char *p3 = db_adapt_translate_path("/data/data/com.termux/cache/apt", buf, sizeof(buf), false);
    assert(strcmp(p3, "/data/user/0/org.example.customapp/files/terminal/cache/apt") == 0);

    const char *p4 = db_adapt_translate_path("/data/data/com.termux.other/files/usr", buf, sizeof(buf), false);
    assert(strcmp(p4, "/data/data/com.termux.other/files/usr") == 0);

    const char *p5 = db_adapt_translate_path("/data/data/com.termux/files", buf, sizeof(buf), false);
    assert(strcmp(p5, "/data/user/0/org.example.customapp/files/terminal/files") == 0);

    setenv("TERMUX__HOME", "/data/user/0/org.example.customapp/files/terminal/files/home", 1);
    setenv("HOME", "/different/shell/home", 1);
    assert(strcmp(db_adapt_translate_path("/data/data/com.termux/files/home/.bashrc", buf, sizeof(buf), false),
                  "/data/user/0/org.example.customapp/files/terminal/files/home/.bashrc") == 0);

    return 0;
}
`
	if err := os.WriteFile(unitSrc, []byte(unitCode), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(cc, "-O2", "-Wall", "-Wextra", "-Werror", "-DDB_TERMUX_ADAPT_TESTING", unitSrc, cSrc, "-o", unitBin).CombinedOutput(); err != nil {
		t.Fatalf("compile unit test failed: %v\n%s", err, string(out))
	}
	if out, err := exec.Command(unitBin).CombinedOutput(); err != nil {
		t.Fatalf("unit test failed: %v\n%s", err, string(out))
	}

	// Build shared library and verify live LD_PRELOAD interception on open/fopen.
	soPath := filepath.Join(tmp, "libdb_termux_adapt.so")
	if out, err := exec.Command(cc, "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror", cSrc, "-ldl", "-o", soPath).CombinedOutput(); err != nil {
		t.Fatalf("compile shared lib failed: %v\n%s", err, string(out))
	}
	prefix := filepath.Join(tmp, "app", "files", "terminal", "files", "usr")
	home := filepath.Join(tmp, "app", "files", "terminal", "files", "home")
	cache := filepath.Join(tmp, "app", "files", "terminal", "cache")
	if err := os.MkdirAll(filepath.Join(prefix, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(prefix, "etc", "adapted.txt"), []byte("ADAPTED_OK"), 0o644); err != nil {
		t.Fatal(err)
	}

	catBin, err := exec.LookPath("cat")
	if err != nil {
		t.Skip("cat not in PATH")
	}
	cmd := exec.Command(catBin, "/data/data/com.termux/files/usr/etc/adapted.txt")
	cmd.Env = append(os.Environ(),
		"LD_PRELOAD="+soPath,
		"PREFIX="+prefix,
		"HOME="+home,
		"TERMUX_CACHE_DIR="+cache,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("LD_PRELOAD cat failed: %v\n%s", err, string(out))
	}
	if strings.TrimSpace(string(out)) != "ADAPTED_OK" {
		t.Fatalf("expected ADAPTED_OK, got %q", string(out))
	}

	rmBin, err := exec.LookPath("rm")
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(prefix, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(rmBin, filepath.Join(bin, "rm")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/bin/sh", filepath.Join(bin, "sh")); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(home, "test-tree")
	if err := os.Mkdir(victim, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(victim, "one"), []byte("fixture"), 0o644); err != nil {
		t.Fatal(err)
	}
	env := append(cmd.Env, "TERMUX__HOME="+home, "HOME="+tmp)
	remove := exec.Command("/bin/sh", "-c", "exec /usr/bin/rm -r /data/data/com.termux/files/home/test-tree")
	remove.Env = env
	if out, err := remove.CombinedOutput(); err != nil {
		t.Fatalf("translated rm failed: %v\n%s", err, out)
	}
	if _, err := os.Stat(victim); !os.IsNotExist(err) {
		t.Fatalf("translated rm did not remove the tree: %v", err)
	}
	script := filepath.Join(home, "no-exec")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho ran\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	deny := exec.Command("/bin/sh", "-c", `exec "$1"`, "sh", script)
	deny.Env = env
	if out, err := deny.CombinedOutput(); err == nil || strings.TrimSpace(string(out)) == "ran" {
		t.Fatalf("non-executable script was run: %q (%v)", out, err)
	}
}
