package synccontrol

import (
	"context"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/storage"
	"devicebridge/protocol"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestControllerNeedsDelegationLiveRootAndNoPathEscape(t *testing.T) {
	ctx := context.Background()
	state := filepath.Join(t.TempDir(), "state")
	root := t.TempDir()
	outside := t.TempDir()
	if e := os.Mkdir(filepath.Join(root, "folder"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, "folder", "data"), []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.Symlink(outside, filepath.Join(root, "escape")); e != nil {
		t.Fatal(e)
	}
	store, e := storage.Open(state)
	if e != nil {
		t.Fatal(e)
	}
	defer store.Close()
	controller := strings.Repeat("a", 64)
	if e = store.Export("shared", root); e != nil {
		t.Fatal(e)
	}
	if e = store.NewInvite("invite", time.Now().Add(time.Minute)); e != nil {
		t.Fatal(e)
	}
	if e = store.RequestPair("invite", controller, "phone"); e != nil {
		t.Fatal(e)
	}
	if e = store.Approve(controller, []string{"shared"}, time.Hour, 1<<30); e != nil {
		t.Fatal(e)
	}
	provider, e := filesproviders.NewNative("shared", root)
	if e != nil {
		t.Fatal(e)
	}
	defer provider.Close()
	registry := &filesproviders.Registry{}
	if e = registry.Register(provider); e != nil {
		t.Fatal(e)
	}
	manager := New(ctx, state, store, registry)
	request := protocol.SyncControl{Operation: "info", Root: "shared", Path: "folder"}
	if _, e = manager.Handle(ctx, controller, request); e == nil {
		t.Fatal("read grant implicitly allowed sync writes")
	}
	yes := true
	if _, e = store.SyncControlAccess(controller, &yes); e != nil {
		t.Fatal(e)
	}
	create := protocol.SyncControl{Operation: "mkdir", Root: "shared", Path: "folder", Name: "new destination"}
	if _, e = manager.Handle(ctx, controller, create); e != nil {
		t.Fatal(e)
	}
	if _, e = manager.Handle(ctx, controller, create); e == nil {
		t.Fatal("folder creation overwrote an existing destination")
	}
	create.Name = "../escape"
	if _, e = manager.Handle(ctx, controller, create); e == nil {
		t.Fatal("folder creation escaped its parent")
	}
	for _, bad := range []protocol.SyncControl{
		{Operation: "info", Root: "shared", Path: "../outside"},
		{Operation: "info", Root: "shared", Path: "escape"},
		{Operation: "info", Root: "not-granted", Path: "folder"},
		{Operation: "info", Root: "shared", Path: "folder", LocalPath: outside},
		{Operation: "info", Root: "shared", Path: "folder", RemoteApproved: true},
	} {
		if _, e = manager.Handle(ctx, controller, bad); e == nil {
			t.Fatalf("unsafe/delegation request accepted: %+v", bad)
		}
	}
	lease, _, e := manager.directory(ctx, controller, request)
	if e != nil {
		t.Fatal(e)
	}
	defer lease.Close()
	if e = os.Rename(filepath.Join(root, "folder"), filepath.Join(root, "moved")); e != nil {
		t.Fatal(e)
	}
	if e = os.Symlink(outside, filepath.Join(root, "folder")); e != nil {
		t.Fatal(e)
	}
	data, e := os.ReadFile(filepath.Join(leasePath(lease), "data"))
	if e != nil || string(data) != "original" {
		t.Fatalf("directory lease escaped: %s %v", data, e)
	}
	if _, _, e = manager.directory(ctx, controller, request); e == nil {
		t.Fatal("new request followed substituted symlink")
	}
	if e = store.Revoke(controller); e != nil {
		t.Fatal(e)
	}
	if e = manager.allowed(controller, "shared", false); e == nil {
		t.Fatal("revoked controller still authorized")
	}
	if _, e = store.SyncControlAccess(controller, nil); e == nil {
		t.Fatal("revoked peer's sync approval survived")
	}
}

func TestLocalStopWhileJobIsPreparing(t *testing.T) {
	state := filepath.Join(t.TempDir(), "state")
	store, err := storage.Open(state)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	manager := New(ctx, state, store, &filesproviders.Registry{})
	manager.WorkerProcess = true
	const group = "test-stop"
	if err := manager.saveBinding(group, Binding{Root: "local"}); err != nil {
		t.Fatal(err)
	}
	id := strings.Repeat("a", 32)
	req := protocol.SyncControl{Operation: "stop", Group: group, Root: "local", JobID: id}
	result, err := manager.Handle(ctx, "", req)
	if err != nil || result.(Job).State != "interrupted" {
		t.Fatalf("preparing job did not accept its stop: %#v, %v", result, err)
	}
	if err := manager.ownerStopped(id); err == nil {
		t.Fatal("job start would continue after stop")
	}
	if err := manager.ownerStopped(strings.Repeat("b", 32)); err != nil {
		t.Fatalf("stop affected a different job: %v", err)
	}
}
