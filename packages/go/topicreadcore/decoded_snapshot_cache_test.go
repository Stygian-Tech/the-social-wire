package topicreadcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDecodedSnapshotCacheAuthoritativeVersionAndScopes(t *testing.T) {
	now := time.Now()
	id := "88888888-1111-1111-1111-111111111111"
	state := &reuseConnector{row: []driver.Value{id, now, now.Add(time.Hour), `["original"]`, "ranked"}}
	db := sql.OpenDB(state)
	defer db.Close()
	cache := &decodedSnapshotCache[string]{}
	phases := map[string]int{}
	ctx := WithFeedPhaseObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ })
	load := func(scope, lang, revision string) []string {
		t.Helper()
		metadata, values, err := cache.load(ctx, db, "sports_personalized_snapshots", id, false, scope, lang, revision, now)
		if err != nil || metadata == nil {
			t.Fatal(metadata, err)
		}
		return values
	}
	first := load("viewer:a", "en", "r1")
	first[0] = "caller mutation"
	if got := load("viewer:a", "en", "r1"); got[0] != "original" || state.queries != 3 || phases["snapshot-cache-hit"] != 1 {
		t.Fatal(got, state.queries, phases)
	}
	for _, fence := range []string{"xmin::text", "ctid::text", "snapshot_id=$1::uuid", "viewer_scope=$2", "language=$3", "preference_revision=$4", "expires_at>$5"} {
		if !strings.Contains(state.query, fence) {
			t.Fatal(fence, state.query)
		}
	}
	load("viewer:b", "en", "r1")
	load("viewer:a", "fr", "r1")
	load("viewer:a", "en", "r2")
	if phases["snapshot-cache-miss"] != 4 {
		t.Fatal(phases)
	}
	state.stamp = "1:(0,2)" // A same-transaction rewrite can retain xmin but changes ctid.
	state.row[3] = `["updated"]`
	if got := load("viewer:a", "en", "r1"); got[0] != "updated" {
		t.Fatal(got)
	}
	state.row = nil
	if metadata, _, err := cache.load(ctx, db, "sports_personalized_snapshots", id, false, "viewer:a", "en", "r1", now); metadata != nil || err != nil {
		t.Fatal(metadata, err)
	}
	state.err = errors.New("database unavailable")
	if metadata, _, err := cache.load(ctx, db, "sports_personalized_snapshots", id, false, "viewer:a", "en", "r1", now); metadata != nil || err == nil {
		t.Fatal(metadata, err)
	}
	state.err = nil
	state.row = []driver.Value{id, now, now, "[\"expired\"]", "ranked"}
	if metadata, _, err := cache.load(ctx, db, "sports_personalized_snapshots", id, false, "viewer:a", "en", "r1", now); metadata != nil || err != nil {
		t.Fatal(metadata, err)
	}
}

func TestDecodedSnapshotCacheMissCancellationAndRowRace(t *testing.T) {
	for _, scenario := range []string{"delete", "cancel"} {
		t.Run(scenario, func(t *testing.T) {
			now := time.Now()
			id := "88888888-1111-1111-1111-111111111111"
			state := &reuseConnector{row: []driver.Value{id, now, now.Add(time.Hour), `["value"]`, "ranked"}}
			db := sql.OpenDB(state)
			defer db.Close()
			cache := &decodedSnapshotCache[string]{}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			state.beforeQuery = func(query string) {
				if strings.HasPrefix(query, "SELECT payload::text") {
					if scenario == "delete" {
						state.row = nil
					} else {
						cancel()
					}
				}
			}
			metadata, _, err := cache.load(ctx, db, "finance_personalized_snapshots", id, false, "viewer", "en", "r", now)
			if metadata != nil || len(cache.entries) != 0 {
				t.Fatal(metadata, cache.entries)
			}
			if scenario == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			if scenario == "delete" && err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestDecodedSnapshotCacheBoundsAndConcurrentAccess(t *testing.T) {
	cache := &decodedSnapshotCache[string]{}
	var group sync.WaitGroup
	for i := 0; i < 50; i++ {
		group.Add(1)
		go func(i int) {
			defer group.Done()
			key := snapshotCacheKey{ID: fmt.Sprint(i)}
			cache.put(key, []string{"value"}, 1<<20)
			cache.get(key)
		}(i)
	}
	group.Wait()
	if len(cache.entries) > decodedSnapshotMaximumEntries || cache.bytes > decodedSnapshotMaximumBytes {
		t.Fatal(len(cache.entries), cache.bytes)
	}
	largeKey := snapshotCacheKey{ID: "oversized"}
	cache.put(largeKey, []string{"large"}, decodedSnapshotMaximumBytes+1)
	if _, ok := cache.get(largeKey); ok {
		t.Fatal("oversized snapshot cached")
	}
	byteCache := &decodedSnapshotCache[string]{}
	for i := 0; i < 3; i++ {
		byteCache.put(snapshotCacheKey{ID: fmt.Sprint(i)}, []string{"large"}, decodedSnapshotMaximumBytes/2)
	}
	if len(byteCache.entries) != 2 || byteCache.bytes != decodedSnapshotMaximumBytes {
		t.Fatal(len(byteCache.entries), byteCache.bytes)
	}
}

func TestPostgresDecodedSnapshotCacheTracksMutationAndDeletion(t *testing.T) {
	db := selectionDB(t)
	now := time.Now().UTC()
	ctx := context.Background()
	for _, domain := range []string{"finance", "sports"} {
		t.Run(domain, func(t *testing.T) {
			generation, snapshot := newID(), newID()
			table := domain + "_personalized_snapshots"
			if _, err := db.Exec(`INSERT INTO `+domain+`_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,'[]')`, generation, now, now.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { db.Exec(`DELETE FROM `+domain+`_generations WHERE generation_id=$1::uuid`, generation) })
			if _, err := db.Exec(`INSERT INTO `+table+`(snapshot_id,source_generation_id,viewer_scope,language,preference_revision,generated_at,expires_at,payload)VALUES($1::uuid,$2::uuid,'snapshot-cache-fixture','en','revision',$3,$4,'["original"]')`, snapshot, generation, now, now.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			cache := &decodedSnapshotCache[string]{}
			load := func(scope, language, revision string) (*snapshotMetadata, []string, error) {
				return cache.load(ctx, db, table, snapshot, false, scope, language, revision, now)
			}
			original, values, err := load("snapshot-cache-fixture", "en", "revision")
			if err != nil || original == nil || values[0] != "original" {
				t.Fatal(original, values, err)
			}
			if _, values, err = load("snapshot-cache-fixture", "en", "revision"); err != nil || values[0] != "original" {
				t.Fatal(values, err)
			}
			for _, scope := range []string{"wrong-viewer", "snapshot-cache-fixture"} {
				lang, revision := "en", "wrong-revision"
				if scope == "wrong-viewer" {
					revision = "revision"
				}
				if metadata, _, err := load(scope, lang, revision); metadata != nil || err != nil {
					t.Fatal(metadata, err)
				}
			}
			if metadata, _, err := load("snapshot-cache-fixture", "fr", "revision"); metadata != nil || err != nil {
				t.Fatal(metadata, err)
			}
			if _, err := db.Exec(`UPDATE `+table+` SET payload='["updated"]' WHERE snapshot_id=$1::uuid`, snapshot); err != nil {
				t.Fatal(err)
			}
			updated, values, err := load("snapshot-cache-fixture", "en", "revision")
			if err != nil || updated == nil || updated.Stamp == original.Stamp || values[0] != "updated" {
				t.Fatal(updated, values, err)
			}
			if _, err := db.Exec(`UPDATE `+table+` SET expires_at=$2 WHERE snapshot_id=$1::uuid`, snapshot, now); err != nil {
				t.Fatal(err)
			}
			if metadata, _, err := load("snapshot-cache-fixture", "en", "revision"); metadata != nil || err != nil {
				t.Fatal(metadata, err)
			}
			if _, err := db.Exec(`DELETE FROM `+table+` WHERE snapshot_id=$1::uuid`, snapshot); err != nil {
				t.Fatal(err)
			}
			if metadata, _, err := load("snapshot-cache-fixture", "en", "revision"); metadata != nil || err != nil {
				t.Fatal(metadata, err)
			}
		})
	}
}
