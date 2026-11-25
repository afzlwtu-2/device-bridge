package projectsync

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"devicebridge/internal/auth"
	"devicebridge/internal/storage"
)

func TestHandoffFreezesThePreviousWriterBeforeAcceptance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	makeJournal := func(name string) Journal {
		t.Helper()
		store, err := storage.Open(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = store.Close() })
		id, err := auth.Load(store, name)
		if err != nil {
			t.Fatal(err)
		}
		return Journal{Store: store, Identity: id}
	}
	sender, target := makeJournal("source"), makeJournal("target")
	if err := sender.Store.TrustOutbound(target.Identity.ID, "target", "paired"); err != nil {
		t.Fatal(err)
	}
	if err := target.Store.TrustOutbound(sender.Identity.ID, "source", "paired"); err != nil {
		t.Fatal(err)
	}
	const group, digest = "workspace", "12ab34cd56ef7890"
	git := GitState{Branch: "main", Head: strings.Repeat("a", 40), Upstream: "origin/main"}
	genesis, err := sender.Initialize(ctx, group, git, digest)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := target.Follow(ctx, genesis); err != nil {
		t.Fatal(err)
	}
	offer, err := sender.Offer(ctx, group, target.Identity.ID, git, digest)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := sender.State(ctx, group)
	if err != nil || loaded.Pending == nil || loaded.CanWrite(sender.Identity.ID) {
		t.Fatalf("handoff did not durably freeze the source: %v", err)
	}
	if _, err := sender.Advance(ctx, group, git, "0123456789abcdef"); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("previous owner staged changes after handoff: %v", err)
	}
	rejection, err := target.Reject(ctx, offer)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := target.Accept(ctx, offer, git, digest); err == nil {
		t.Fatal("target accepted a durably rejected offer")
	}
	unfrozen, err := sender.Cancel(ctx, rejection)
	if err != nil || !unfrozen.CanWrite(sender.Identity.ID) {
		t.Fatalf("signed rejection did not recover the source writer: %v", err)
	}
	newOffer, err := sender.Offer(ctx, group, target.Identity.ID, git, digest)
	if err != nil || offer.Pending.Revision.Hash() == newOffer.Pending.Revision.Hash() {
		t.Fatalf("a later offer must use a distinct signed nonce: %v", err)
	}
	offer = newOffer
	if _, err := target.Accept(ctx, offer, git, "0123456789abcdef"); err == nil {
		t.Fatal("handoff accepted a mismatched projection")
	}
	receipt, err := target.Accept(ctx, offer, git, digest)
	if err != nil || !receipt.CanWrite(target.Identity.ID) || receipt.Current().Epoch != 2 {
		t.Fatalf("new owner was not verified: %v", err)
	}
	acknowledged, err := target.Accept(ctx, offer, git, digest)
	if err != nil || acknowledged.Current().Hash() != receipt.Current().Hash() {
		t.Fatalf("retry did not recover the same signed receipt: %v", err)
	}
	fake := append([]SignedRevision(nil), receipt.Chain...)
	fake[len(fake)-1].Revision.Manifest = "ffffffffffffffff"
	if _, err := sender.Finalize(ctx, JournalState{Chain: fake}); err == nil {
		t.Fatal("tampered ownership receipt was accepted")
	}
	final, err := sender.Finalize(ctx, receipt)
	if err != nil || final.CanWrite(sender.Identity.ID) || final.Pending != nil {
		t.Fatalf("prior source did not become read-only: %v", err)
	}
	if _, err := sender.Advance(ctx, group, git, digest); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("stale writer lockout did not survive finalization: %v", err)
	}
}
