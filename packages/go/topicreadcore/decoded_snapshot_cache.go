package topicreadcore

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

const decodedSnapshotMaximumEntries = 8
const decodedSnapshotMaximumBytes = 32 << 20

type snapshotMetadata struct {
	ID                     string
	GeneratedAt, ExpiresAt time.Time
	Source, Stamp          string
}
type snapshotCacheKey struct{ ID, Scope, Language, Revision, Stamp string }
type decodedSnapshotEntry[Candidate any] struct {
	Candidates []Candidate
	Bytes      int
	Access     uint64
}

// Rows, expiry, viewer scope and preference revision remain database-authoritative.
// Only immutable decoded candidate values are memoized; every hit rechecks row version.
type decodedSnapshotCache[Candidate any] struct {
	mu      sync.Mutex
	entries map[snapshotCacheKey]decodedSnapshotEntry[Candidate]
	bytes   int
	access  uint64
}

func (cache *decodedSnapshotCache[Candidate]) get(key snapshotCacheKey) ([]Candidate, bool) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	entry, ok := cache.entries[key]
	if !ok {
		return nil, false
	}
	cache.access++
	entry.Access = cache.access
	cache.entries[key] = entry
	return append([]Candidate{}, entry.Candidates...), true
}
func (cache *decodedSnapshotCache[Candidate]) put(key snapshotCacheKey, candidates []Candidate, size int) {
	if size > decodedSnapshotMaximumBytes {
		return
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.entries == nil {
		cache.entries = map[snapshotCacheKey]decodedSnapshotEntry[Candidate]{}
	}
	// Discard old versions of this exact scoped snapshot immediately.
	for old, entry := range cache.entries {
		if old.ID == key.ID && old.Scope == key.Scope && old.Language == key.Language && old.Revision == key.Revision {
			cache.bytes -= entry.Bytes
			delete(cache.entries, old)
		}
	}
	for len(cache.entries) >= decodedSnapshotMaximumEntries || cache.bytes+size > decodedSnapshotMaximumBytes {
		var oldest snapshotCacheKey
		var oldestAccess uint64
		found := false
		for candidate, entry := range cache.entries {
			if !found || entry.Access < oldestAccess {
				oldest = candidate
				oldestAccess = entry.Access
				found = true
			}
		}
		if !found {
			break
		}
		cache.bytes -= cache.entries[oldest].Bytes
		delete(cache.entries, oldest)
	}
	cache.access++
	cache.entries[key] = decodedSnapshotEntry[Candidate]{append([]Candidate{}, candidates...), size, cache.access}
	cache.bytes += size
}

func (cache *decodedSnapshotCache[Candidate]) load(ctx context.Context, db *sql.DB, table string, lookup string, reusable bool, scope, language, revision string, now time.Time) (*snapshotMetadata, []Candidate, error) {
	// table and identity column are fixed by the two typed store callers.
	column := "snapshot_id"
	if reusable {
		column = "source_generation_id"
	}
	metadata := snapshotMetadata{}
	started := time.Now()
	query := `SELECT snapshot_id::text,generated_at,expires_at,serving_source,xmin::text||':'||ctid::text FROM ` + table + ` WHERE ` + column + `=$1::uuid AND viewer_scope=$2 AND language=$3 AND preference_revision=$4 AND expires_at>$5`
	err := db.QueryRowContext(ctx, query, lookup, scope, language, revision, now).Scan(&metadata.ID, &metadata.GeneratedAt, &metadata.ExpiresAt, &metadata.Source, &metadata.Stamp)
	ObserveFeedPhase(ctx, "snapshot-query", time.Since(started))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, nil, err
	}
	if !metadata.ExpiresAt.After(now) {
		return nil, nil, nil
	}
	key := snapshotCacheKey{metadata.ID, scope, language, revision, metadata.Stamp}
	if candidates, ok := cache.get(key); ok {
		ObserveFeedPhase(ctx, "snapshot-cache-hit", 0)
		return &metadata, candidates, nil
	}
	ObserveFeedPhase(ctx, "snapshot-cache-miss", 0)
	var raw []byte
	started = time.Now()
	err = db.QueryRowContext(ctx, `SELECT payload::text FROM `+table+` WHERE snapshot_id=$1::uuid AND viewer_scope=$2 AND language=$3 AND preference_revision=$4 AND expires_at>$5 AND xmin::text||':'||ctid::text=$6`, metadata.ID, scope, language, revision, now, metadata.Stamp).Scan(&raw)
	ObserveFeedPhase(ctx, "snapshot-query", time.Since(started))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	candidates := []Candidate{}
	started = time.Now()
	err = corpuscore.DecodeContract(raw, &candidates)
	ObserveFeedPhase(ctx, "snapshot-decode", time.Since(started))
	if err != nil {
		return nil, nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, nil, err
	}
	cache.put(key, candidates, len(raw))
	return &metadata, candidates, nil
}
