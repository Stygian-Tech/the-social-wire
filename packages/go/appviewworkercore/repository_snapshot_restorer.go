package appviewworkercore

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

const signedSnapshotMode = "signed_blocks_v1"

// A verified revision has its own observation set. Never combine records from
// different revisions when deciding which old projected records may be pruned.
func (r RepositoryRestorer) restoreSignedSnapshot(ctx context.Context, store thinappviewcore.RecoveryStore, scope thinappviewcore.RecoveryContext, state thinappviewcore.RecoveryState) error {
	collections := []string{"site.standard.document", "site.standard.entry"}
	source := r.Snapshots
	if source == nil {
		source = thinappviewcore.RepositorySnapshotReader{PDS: r.PDS}
	}
	snapshotStartedAt := r.Projector.clock()
	snapshot, err := source.Read(ctx, scope.RepoDID, collections)
	if err != nil {
		return err
	}
	if snapshot.CommitCID == "" || snapshot.Revision == "" || snapshot.PDSBase == "" {
		return errors.New("repository snapshot identity unavailable")
	}
	// Verify injected sources as well; production reader already enforces these.
	for _, record := range snapshot.Records {
		prefix := "at://" + scope.RepoDID + "/"
		if !strings.HasPrefix(record.URI, prefix) {
			return errors.New("repository snapshot record scope invalid")
		}
		parts := strings.Split(strings.TrimPrefix(record.URI, prefix), "/")
		if len(parts) != 2 || (parts[0] != collections[0] && parts[0] != collections[1]) || parts[1] == "" || record.CID == "" {
			return errors.New("repository snapshot record scope invalid")
		}
	}
	if state.SnapshotMode != signedSnapshotMode || state.CommitCID != snapshot.CommitCID || state.Revision != snapshot.Revision || state.PDSBase == nil || *state.PDSBase != snapshot.PDSBase {
		token, err := newSnapshotToken()
		if err != nil {
			return err
		}
		state = thinappviewcore.RecoveryState{SnapshotID: token, SnapshotMode: signedSnapshotMode, CommitCID: snapshot.CommitCID, Revision: snapshot.Revision, StartedAt: thinappviewcore.SwiftDate{Time: snapshotStartedAt}, PDSBase: &snapshot.PDSBase, Collections: map[string]thinappviewcore.RecoveryCollection{}}
		state, err = store.Save(ctx, scope, state, nil, false)
		if err != nil {
			return err
		}
	}
	if state.RecordOffset < 0 || state.RecordOffset > len(snapshot.Records) {
		return errors.New("repository snapshot checkpoint invalid")
	}
	budget := r.RecordBudget
	if budget <= 0 {
		budget = 200
	}
	budget = min(200, budget)
	end := min(len(snapshot.Records), state.RecordOffset+budget)
	uris := make([]string, 0, end-state.RecordOffset)
	for _, record := range snapshot.Records[state.RecordOffset:end] {
		parts := strings.Split(strings.TrimPrefix(record.URI, "at://"+scope.RepoDID+"/"), "/")
		if err := r.Projector.Commit(ctx, scope.RepoDID, parts[0], parts[1], record.CID, "create", "", record.Value, time.Now(), snapshot.PDSBase); err != nil {
			return err
		}
		count := state.Collections[parts[0]]
		count.ObservedCount++
		count.IndexedCount++
		state.Collections[parts[0]] = count
		uris = append(uris, record.URI)
	}
	state.RecordOffset = end
	if end == len(snapshot.Records) {
		for _, collection := range collections {
			progress := state.Collections[collection]
			progress.Complete = true
			state.Collections[collection] = progress
		}
	}
	state, err = store.Save(ctx, scope, state, uris, false)
	if err != nil {
		return err
	}
	if end < len(snapshot.Records) {
		return r.yield(ctx, store, scope)
	}
	state, err = store.Save(ctx, scope, state, nil, true)
	if err != nil {
		return err
	}
	if !state.Completed {
		return r.yield(ctx, store, scope)
	}
	return r.finalize(ctx, scope.RepoDID)
}
