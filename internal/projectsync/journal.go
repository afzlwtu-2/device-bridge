package projectsync

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"devicebridge/internal/auth"
	"devicebridge/internal/storage"
)

type Journal struct {
	Store    *storage.Store
	Identity *auth.Identity
}

var ErrNotRegistered = errors.New("the project group is not registered")
var ErrReadOnly = errors.New("this device is read-only for the project")

func (j Journal) State(ctx context.Context, group string) (JournalState, error) {
	state, _, err := j.load(ctx, group)
	return state, err
}

func journalKey(group string) string {
	return "project-ownership-v1:" + group
}

func (j Journal) load(ctx context.Context, group string) (JournalState, string, error) {
	var state JournalState
	if !groupID.MatchString(group) {
		return state, "", errors.New("invalid project group ID")
	}
	var raw string
	err := j.Store.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", journalKey(group)).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return state, "", ErrNotRegistered
	}
	if err != nil {
		return state, "", err
	}
	if len(raw) > MaxChainBytes || json.Unmarshal([]byte(raw), &state) != nil || state.Validate() != nil || state.Current().Group != group {
		return JournalState{}, "", errors.New("the local ownership journal is invalid")
	}
	return state, raw, nil
}

func (j Journal) save(ctx context.Context, state JournalState, old string) (JournalState, error) {
	if err := state.Validate(); err != nil {
		return JournalState{}, err
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return JournalState{}, err
	}
	if len(raw) > MaxChainBytes {
		return JournalState{}, errors.New("the project journal exceeds the supported size")
	}
	group := journalKey(state.Current().Group)
	var result sql.Result
	if old == "" {
		result, err = j.Store.DB.ExecContext(ctx, "INSERT OR IGNORE INTO preferences(key,value) VALUES(?,?)", group, string(raw))
	} else {
		result, err = j.Store.DB.ExecContext(ctx, "UPDATE preferences SET value=? WHERE key=? AND value=?", string(raw), group, old)
	}
	if err != nil {
		return JournalState{}, err
	}
	count, err := result.RowsAffected()
	if err != nil || count != 1 {
		return JournalState{}, errors.Join(errors.New("the project journal changed concurrently"), err)
	}
	return state, nil
}

func (j Journal) peer(id string) error {
	p, err := j.Store.Peer(id)
	if err != nil || p.Status != "paired" {
		return errors.New("pair with the other DeviceBridge device before handing off ownership")
	}
	return nil
}

func (j Journal) record(r Revision) (SignedRevision, error) {
	proof, err := signProof(j.Identity, r, "author", r.Issued)
	return SignedRevision{Revision: r, Author: proof}, err
}

func (j Journal) Initialize(ctx context.Context, group string, git GitState, digest string) (JournalState, error) {
	r := Revision{
		Version: 1, Group: group, Sequence: 1, Epoch: 1, Owner: j.Identity.ID,
		Branch: git.Branch, Head: git.Head, Manifest: digest, Issued: time.Now().Unix(),
	}
	entry, err := j.record(r)
	if err != nil {
		return JournalState{}, err
	}
	return j.save(ctx, JournalState{Chain: []SignedRevision{entry}}, "")
}

func (j Journal) Advance(ctx context.Context, group string, git GitState, digest string) (JournalState, error) {
	state, old, err := j.load(ctx, group)
	if err != nil {
		return state, err
	}
	if !state.CanWrite(j.Identity.ID) {
		return state, ErrReadOnly
	}
	r := state.Current()
	if r.matches(git, digest) {
		return state, nil
	}
	r.Parent, r.Sequence, r.Issued = r.Hash(), r.Sequence+1, time.Now().Unix()
	r.Branch, r.Head, r.Manifest, r.Expires = git.Branch, git.Head, digest, 0
	r.Nonce = ""
	next, err := j.record(r)
	if err != nil {
		return state, err
	}
	state.Chain = append(state.Chain, next)
	return j.save(ctx, state, old)
}

func (j Journal) Offer(ctx context.Context, group, target string, git GitState, digest string) (JournalState, error) {
	state, old, err := j.load(ctx, group)
	if err != nil {
		return state, err
	}
	current := state.Current()
	if target == j.Identity.ID || !current.matches(git, digest) {
		return state, errors.New("handoff needs a different paired writer and the approved project contents")
	}
	if err := j.peer(target); err != nil {
		return state, err
	}
	if state.Pending != nil && current.Owner == j.Identity.ID && state.Pending.Revision.Owner == target {
		return state, nil
	}
	if !state.CanWrite(j.Identity.ID) {
		return state, ErrReadOnly
	}
	r := current
	r.Parent, r.Sequence, r.Epoch = current.Hash(), r.Sequence+1, r.Epoch+1
	r.Owner, r.Issued = target, time.Now().Unix()
	r.Expires = r.Issued + int64(offerLifetime/time.Second)
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return state, err
	}
	r.Nonce = hex.EncodeToString(nonce[:])
	proposed, err := j.record(r)
	if err != nil {
		return state, err
	}
	state.Pending = &proposed
	// Persist the sender's write lock before returning an offer to the caller.
	return j.save(ctx, state, old)
}

func (j Journal) Accept(ctx context.Context, incoming JournalState, git GitState, digest string) (JournalState, error) {
	if err := incoming.Validate(); err != nil {
		return JournalState{}, err
	}
	if incoming.Pending == nil {
		return JournalState{}, errors.New("a signed pending handoff is required")
	}
	proposed := *incoming.Pending
	r := proposed.Revision
	if r.Owner != j.Identity.ID || !r.matches(git, digest) {
		return JournalState{}, errors.New("this device needs the same Git revision and verified projection to accept")
	}
	if err := j.peer(incoming.Current().Owner); err != nil {
		return JournalState{}, err
	}
	local, old, err := j.load(ctx, r.Group)
	if slices.Contains(local.Rejected, r.Hash()) {
		return local, errors.New("this device has already rejected the handoff")
	}
	if err == nil && local.Current().Hash() == r.Hash() && local.Pending == nil {
		return local, nil
	}
	if err != nil && !errors.Is(err, ErrNotRegistered) {
		return local, err
	}
	if local.Pending != nil || !chainPrefix(local.Chain, incoming.Chain) {
		return local, errors.New("handoff conflicts with the local ownership history")
	}
	now := time.Now().Unix()
	if now < r.Issued || now > r.Expires {
		return local, errors.New("the handoff offer expired or the device clocks disagree")
	}
	ack, err := signProof(j.Identity, r, "accept", now)
	if err != nil {
		return local, err
	}
	proposed.Accepted = &ack
	incoming.Chain = append(incoming.Chain, proposed)
	incoming.Pending = nil
	incoming.Rejected = local.Rejected
	return j.save(ctx, incoming, old)
}

func (j Journal) Finalize(ctx context.Context, receipt JournalState) (JournalState, error) {
	if err := receipt.Validate(); err != nil {
		return JournalState{}, err
	}
	group := receipt.Current().Group
	state, old, err := j.load(ctx, group)
	if err != nil {
		return state, err
	}
	if state.Pending == nil && state.Current().Hash() == receipt.Current().Hash() {
		return state, nil
	}
	if receipt.Pending != nil || state.Pending == nil || state.Current().Owner != j.Identity.ID ||
		!chainPrefix(state.Chain, receipt.Chain) || len(receipt.Chain) != len(state.Chain)+1 ||
		receipt.Current().Hash() != state.Pending.Revision.Hash() {
		return state, errors.New("receipt does not match the locally frozen offer")
	}
	receipt.Rejected = state.Rejected
	return j.save(ctx, receipt, old)
}

func (j Journal) Follow(ctx context.Context, incoming JournalState) (JournalState, error) {
	if err := incoming.Validate(); err != nil {
		return JournalState{}, err
	}
	if incoming.Pending != nil || incoming.Current().Owner == j.Identity.ID {
		return JournalState{}, errors.New("follow a confirmed revision from another owner")
	}
	if err := j.peer(incoming.Current().Owner); err != nil {
		return JournalState{}, err
	}
	local, old, err := j.load(ctx, incoming.Current().Group)
	if err != nil && !errors.Is(err, ErrNotRegistered) {
		return local, err
	}
	if local.Pending != nil || !chainPrefix(local.Chain, incoming.Chain) {
		return local, errors.New("incoming revisions conflict with the local ownership history")
	}
	incoming.Rejected = local.Rejected
	return j.save(ctx, incoming, old)
}

func (j Journal) Reject(ctx context.Context, incoming JournalState) (Rejection, error) {
	var result Rejection
	if err := incoming.Validate(); err != nil {
		return result, err
	}
	if incoming.Pending == nil || incoming.Pending.Revision.Owner != j.Identity.ID {
		return result, errors.New("a pending offer addressed to this device is required")
	}
	if err := j.peer(incoming.Current().Owner); err != nil {
		return result, err
	}
	proposal := incoming.Pending.Revision
	hash := proposal.Hash()
	local, old, err := j.load(ctx, proposal.Group)
	if err != nil && !errors.Is(err, ErrNotRegistered) {
		return result, err
	}
	if local.Pending != nil || !chainPrefix(local.Chain, incoming.Chain) {
		return result, errors.New("the local journal has already moved past this offer")
	}
	now := time.Now().Unix()
	if now < proposal.Issued {
		return result, errors.New("the device clocks disagree")
	}
	proof, err := signProof(j.Identity, proposal, "reject", now)
	if err != nil {
		return result, err
	}
	if !slices.Contains(local.Rejected, hash) {
		rejected := JournalState{Chain: incoming.Chain, Rejected: append(local.Rejected, hash)}
		if _, err := j.save(ctx, rejected, old); err != nil {
			return result, err
		}
	}
	return Rejection{Group: proposal.Group, Revision: hash, Target: proof}, nil
}

func (j Journal) Cancel(ctx context.Context, receipt Rejection) (JournalState, error) {
	state, old, err := j.load(ctx, receipt.Group)
	if err != nil {
		return state, err
	}
	if state.Pending == nil || state.Current().Owner != j.Identity.ID {
		return state, errors.New("only the previous writer can cancel its frozen offer")
	}
	proposal := state.Pending.Revision
	if proposal.Hash() != receipt.Revision || receipt.Target.Signed < proposal.Issued {
		return state, errors.New("rejection does not match the locally frozen offer")
	}
	if err := verifyProof(receipt.Target, proposal, "reject", proposal.Owner); err != nil {
		return state, err
	}
	state.Pending = nil
	return j.save(ctx, state, old)
}
