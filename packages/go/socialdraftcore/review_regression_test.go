package socialdraftcore

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)

type pausedReader struct {
	ctx              context.Context
	entered, release chan struct{}
	once             sync.Once
	reader           *bytes.Reader
}

func (r *pausedReader) Read(p []byte) (int, error) {
	r.once.Do(func() { close(r.entered) })
	select {
	case <-r.ctx.Done():
		return 0, r.ctx.Err()
	case <-r.release:
		return r.reader.Read(p)
	}
}
func startPausedUpload(t *testing.T, s *Service, owner, id string, b []byte) (*pausedReader, <-chan error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	r := &pausedReader{ctx: ctx, entered: make(chan struct{}), release: make(chan struct{}), reader: bytes.NewReader(b)}
	done := make(chan error, 1)
	go func() { _, e := s.Upload(ctx, owner, id, r, int64(len(b))); done <- e }()
	select {
	case <-r.entered:
	case e := <-done:
		t.Fatalf("upload stopped before body: %v", e)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	return r, done
}
func uploadResult(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case e := <-done:
		return e
	case <-time.After(5 * time.Second):
		t.Fatal("upload did not finish")
		return nil
	}
}

func TestAdmissionBoundedBeforeConnections(t *testing.T) {
	db := &sql.DB{}
	db.SetMaxOpenConns(16)
	s := &Service{db: db}
	var releases []func()
	for i := 0; i < 4; i++ {
		release, e := s.admit(context.Background(), fmt.Sprintf("did:plc:%d", i))
		if e != nil {
			t.Fatal(e)
		}
		releases = append(releases, release)
	}
	if _, e := s.admit(context.Background(), "did:plc:fifth"); e != ErrUnavailable {
		t.Fatal(e)
	}
	releases[0]()
	releases[0]()
	release, e := s.admit(context.Background(), "did:plc:fifth")
	if e != nil {
		t.Fatal(e)
	}
	defer release()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = s.admit(ctx, "did:plc:cancelled"); e != context.Canceled {
		t.Fatal(e)
	}
	for _, r := range releases {
		r()
	}
}

func TestPostgresSlowUploadHasNoTransactionOrPoolWaiters(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n\nprivate\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	r, done := startPausedUpload(t, s, ownerA, assetA, b)
	before := s.db.Stats()
	if before.InUse != 0 {
		t.Fatalf("slow client holds %d connections", before.InUse)
	}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := s.Manifest(ctx, ownerA, draftA); e != ErrUnavailable {
				t.Errorf("owner waiter: %v", e)
			}
		}()
	}
	wg.Wait()
	after := s.db.Stats()
	if after.InUse != 0 || after.WaitCount != before.WaitCount {
		t.Fatalf("waiters reached pool: before=%+v after=%+v", before, after)
	}
	if _, e := s.Reserve(ctx, ownerB, reserveInput(assetA, b)); e != nil {
		t.Fatalf("other owner blocked: %v", e)
	}
	close(r.release)
	if e := uploadResult(t, done); e != nil {
		t.Fatal(e)
	}
}

func TestPostgresUploadSpoolCannotResurrectPurgedAsset(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n\nprivate\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	r, done := startPausedUpload(t, s, ownerA, assetA, b)
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()-interval '25 hours'`); e != nil {
		t.Fatal(e)
	}
	if n, e := replica(s).Cleanup(ctx, 1); e != nil || n != 1 {
		t.Fatalf("concurrent cleanup %d %v", n, e)
	}
	close(r.release)
	if e := uploadResult(t, done); e != ErrNotFound {
		t.Fatalf("resurrection: %v", e)
	}
	if len(f.objects) != 0 {
		t.Fatal("upload wrote after cleanup")
	}
}

func TestPostgresReadyRetryCannotUndoDeletionDuringSpool(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	ready(t, s, ownerA, assetA)
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption"}}}); e != nil {
		t.Fatal(e)
	}
	b := []byte("WEBVTT\n\n00:00.000 --> 00:01.000\nprivate\n")
	r, done := startPausedUpload(t, s, ownerA, assetA, b)
	other := replica(s)
	if _, e := other.DeleteManifest(ctx, ownerA, draftA, 1); e != nil {
		t.Fatal(e)
	}
	if n, e := other.Cleanup(ctx, 1); e != nil || n != 1 {
		t.Fatalf("cleanup %d %v", n, e)
	}
	close(r.release)
	if e := uploadResult(t, done); e != ErrNotFound {
		t.Fatal(e)
	}
	if len(f.objects) != 0 {
		t.Fatal("resurrected object")
	}
}

func TestPostgresCrossReplicaLockDoesNotWait(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`SELECT owner FROM private_social_draft_accounts WHERE owner=$1 FOR UPDATE`, ownerA); e != nil {
		t.Fatal(e)
	}
	started := time.Now()
	if _, e := replica(s).Reserve(ctx, ownerA, reserveInput(assetB, b)); e != ErrUnavailable {
		t.Fatal(e)
	}
	if time.Since(started) > time.Second {
		t.Fatal("cross-replica owner contention waited")
	}
}

func TestPostgresPendingDeletionRetainsByteQuota(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	ready(t, s, ownerA, assetA)
	// Charge this tiny test object as a maximum-size file to avoid allocating a
	// gigabyte while exercising the production aggregate quota query.
	if _, e := s.db.Exec(`UPDATE private_social_draft_assets SET byte_length=$1 WHERE owner=$2`, MaxFileBytes, ownerA); e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 9; i++ {
		in := reserveInput(fmt.Sprintf("%08x-3333-4333-8333-333333333333", i), []byte("WEBVTT\n"))
		in.ByteLength = MaxFileBytes
		if _, e := s.Reserve(ctx, ownerA, in); e != nil {
			t.Fatal(e)
		}
	}
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption"}}}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.DeleteManifest(ctx, ownerA, draftA, 1); e != nil {
		t.Fatal(e)
	}
	extra := reserveInput(assetB, []byte("WEBVTT\n"))
	extra.ByteLength = MaxFileBytes
	if _, e := s.Reserve(ctx, ownerA, extra); e != ErrQuota {
		t.Fatalf("revoked asset uncharged: %v", e)
	}
	f.failDelete = true
	if _, e := s.Cleanup(ctx, 1); e != ErrUnavailable {
		t.Fatal(e)
	}
	if _, e := s.Reserve(ctx, ownerA, extra); e != ErrQuota {
		t.Fatalf("failed deletion uncharged: %v", e)
	}
	f.failDelete = false
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now() WHERE owner=$1 AND asset_id=$2`, ownerA, assetA); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); n != 1 || e != nil {
		t.Fatalf("purge %d %v", n, e)
	}
	if _, e := s.Reserve(ctx, ownerA, extra); e != nil {
		t.Fatalf("confirmed purge did not release quota: %v", e)
	}
	var state string
	var metadata []byte
	if e := s.db.QueryRow(`SELECT state,metadata FROM private_social_draft_assets WHERE owner=$1 AND asset_id=$2`, ownerA, assetA).Scan(&state, &metadata); e != nil || state != "purged" || len(metadata) != 0 {
		t.Fatalf("purged metadata %s %v", state, e)
	}
}

func TestPostgresCleanupOldestDueAndNoReferencedJobs(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	ready(t, s, ownerA, assetA)
	ready(t, s, ownerB, assetA)
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=CASE WHEN owner=$1 THEN now()-interval '1 hour' ELSE now()-interval '2 hours' END`, ownerA); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); e != nil || n != 1 {
		t.Fatalf("cleanup %d %v", n, e)
	}
	var state string
	if e := s.db.QueryRow(`SELECT state FROM private_social_draft_assets WHERE owner=$1`, ownerB).Scan(&state); e != nil || state != "purged" {
		t.Fatalf("oldest later owner starved: %s %v", state, e)
	}
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption"}}}); e != nil {
		t.Fatal(e)
	}
	var count int
	if e := s.db.QueryRow(`SELECT count(*) FROM private_social_draft_cleanup WHERE owner=$1`, ownerA).Scan(&count); e != nil || count != 0 {
		t.Fatalf("referenced periodic jobs: %d %v", count, e)
	}
	// Defensive cleanup also removes any legacy referenced job once, never reschedules it.
	if _, e := s.db.Exec(`INSERT INTO private_social_draft_cleanup(owner,asset_id,available_at) VALUES($1,$2,now())`, ownerA, assetA); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); e != nil || n != 0 {
		t.Fatalf("referenced cleanup %d %v", n, e)
	}
	if e := s.db.QueryRow(`SELECT count(*) FROM private_social_draft_cleanup`).Scan(&count); e != nil || count != 0 {
		t.Fatalf("referenced rescheduled: %d %v", count, e)
	}
	if _, e := s.DeleteManifest(ctx, ownerA, draftA, 1); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); e != nil || n != 1 {
		t.Fatalf("final detach did not queue: %d %v", n, e)
	}
}

// A blocked S3 PUT still owns the DB lock; GC must skip it and cannot orphan a
// late ready finalization. The bytes being uploaded here are already local.
type pausedStore struct {
	objectStore
	entered, release chan struct{}
}

func (s *pausedStore) Put(ctx context.Context, k string, r io.ReadSeeker, n int64) error {
	close(s.entered)
	select {
	case <-s.release:
		return s.objectStore.Put(ctx, k, r, n)
	case <-ctx.Done():
		return ctx.Err()
	}
}
func TestPostgresCleanupSkipsFinalizingUpload(t *testing.T) {
	s, f := integrationService(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	b := []byte("WEBVTT\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	p := &pausedStore{objectStore: f, entered: make(chan struct{}), release: make(chan struct{})}
	s.objects = p
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()`); e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() { _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b), int64(len(b))); done <- e }()
	select {
	case <-p.entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if n, e := replica(s).Cleanup(ctx, 1); e != nil || n != 0 {
		t.Fatalf("GC acquired uploading asset %d %v", n, e)
	}
	close(p.release)
	if e := uploadResult(t, done); e != nil {
		t.Fatal(e)
	}
	if r, _, e := s.Download(ctx, ownerA, assetA); e != nil {
		t.Fatal(e)
	} else {
		r.Close()
	}
}

func TestPostgresPendingDeletionRetainsAssetCountQuota(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	// Generate tiny pending-deletion rows to exercise count limits independently
	// of the byte limit. Production creates each row through Reserve and detach.
	if _, e := s.db.Exec(`INSERT INTO private_social_draft_assets(owner,asset_id,metadata,byte_length,object_key,state)
 SELECT owner,(lpad(to_hex(i),8,'0')||'-4444-4444-8444-444444444444')::uuid,metadata,1,'count-test-'||i,'deleted'
 FROM private_social_draft_assets CROSS JOIN generate_series(1,9999) i WHERE owner=$1 AND asset_id=$2`, ownerA, assetA); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetB, b)); e != ErrQuota {
		t.Fatalf("pending count uncharged: %v", e)
	}
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()`); e != nil {
		t.Fatal(e)
	}
	if n, e := s.Cleanup(ctx, 1); n != 1 || e != nil {
		t.Fatalf("purge %d %v", n, e)
	}
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetB, b)); e != nil {
		t.Fatalf("purge did not release count slot: %v", e)
	}
}
