package socialdraftcore

import (
	"context"
	"errors"
	"testing"
	"time"
)

type deadlineDeleteStore struct {
	objectStore
	blockedKey   string
	afterTimeout func()
}

func (s *deadlineDeleteStore) Delete(ctx context.Context, key string) error {
	if key != s.blockedKey {
		return s.objectStore.Delete(ctx, key)
	}
	<-ctx.Done()
	if s.afterTimeout != nil {
		s.afterTimeout()
	}
	return ctx.Err()
}

func TestPostgresCleanupDeleteDeadlinePersistsBackoff(t *testing.T) {
	for _, cancelSweep := range []bool{false, true} {
		name := "remaining sweep processes later owner"
		if cancelSweep {
			name = "cancelled sweep still persists backoff"
		}
		t.Run(name, func(t *testing.T) {
			s, f := integrationService(t)
			ready(t, s, ownerA, assetA)
			ready(t, s, ownerB, assetA)
			var key string
			if e := s.db.QueryRow(`SELECT object_key FROM private_social_draft_assets WHERE owner=$1`, ownerA).Scan(&key); e != nil {
				t.Fatal(e)
			}
			if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=CASE WHEN owner=$1 THEN now()-interval '2 hours' ELSE now()-interval '1 hour' END`, ownerA); e != nil {
				t.Fatal(e)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			store := &deadlineDeleteStore{objectStore: f, blockedKey: key}
			if cancelSweep {
				store.afterTimeout = cancel
			}
			s.objects = store
			n, e := s.Cleanup(ctx, 2)
			if cancelSweep {
				if !errors.Is(e, context.Canceled) || n != 0 {
					t.Fatalf("cancelled cleanup n=%d error=%v", n, e)
				}
			} else {
				if e != ErrUnavailable || n != 1 {
					t.Fatalf("cleanup n=%d error=%v", n, e)
				}
				if ctx.Err() != nil {
					t.Fatal("object used entire sweep deadline")
				}
			}
			var attempts int
			var deferred bool
			var state string
			if e := s.db.QueryRow(`SELECT attempts,available_at>now() FROM private_social_draft_cleanup WHERE owner=$1`, ownerA).Scan(&attempts, &deferred); e != nil || attempts != 1 || !deferred {
				t.Fatalf("backoff not committed: attempts=%d deferred=%v error=%v", attempts, deferred, e)
			}
			if e := s.db.QueryRow(`SELECT state FROM private_social_draft_assets WHERE owner=$1`, ownerA).Scan(&state); e != nil || state != "deleted" {
				t.Fatalf("pending deletion state=%s error=%v", state, e)
			}
			f.mu.Lock()
			_, exists := f.objects[key]
			f.mu.Unlock()
			if !exists {
				t.Fatal("timed-out delete should retain its object")
			}
			if cancelSweep {
				// The deferred oldest job must not monopolize the next sweep either.
				if n, e := s.Cleanup(context.Background(), 1); e != nil || n != 1 {
					t.Fatalf("next sweep could not reach later owner n=%d error=%v", n, e)
				}
			}
			if e := s.db.QueryRow(`SELECT state FROM private_social_draft_assets WHERE owner=$1`, ownerB).Scan(&state); e != nil || state != "purged" {
				t.Fatalf("later owner starved state=%s error=%v", state, e)
			}
		})
	}
}

func TestPostgresRetiredReservationDistinctFromRevisionConflict(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n")
	in := reserveInput(assetA, b)
	if _, e := s.Reserve(ctx, ownerA, in); e != nil {
		t.Fatal(e)
	}
	changed := in
	changed.Name = "different.vtt"
	if _, e := s.Reserve(ctx, ownerA, changed); e != ErrConflict || errors.Is(e, ErrAssetRetired) {
		t.Fatalf("active metadata mismatch: %v", e)
	}
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()`); e != nil {
		t.Fatal(e)
	}
	f.failDelete = true
	if _, e := s.Cleanup(ctx, 1); e != ErrUnavailable {
		t.Fatal(e)
	}
	assertRetired := func() {
		t.Helper()
		for _, metadata := range []ReserveInput{in, changed} {
			if _, e := s.Reserve(ctx, ownerA, metadata); e != ErrAssetRetired || !errors.Is(e, ErrConflict) {
				t.Fatalf("retired reservation should wrap conflict: %v", e)
			}
		}
	}
	assertRetired()
	f.failDelete = false
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()`); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); n != 1 || e != nil {
		t.Fatalf("purge %d %v", n, e)
	}
	assertRetired()
	if _, e := s.Reserve(ctx, ownerB, in); e != nil {
		t.Fatalf("retirement leaked across owner namespace: %v", e)
	}
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, ExpectedRevision: 1}); e != ErrConflict || errors.Is(e, ErrAssetRetired) {
		t.Fatalf("manifest revision error: %v", e)
	}
}
