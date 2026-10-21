package socialdraftcore

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

type fakeObjectStore struct {
	mu                  sync.Mutex
	objects             map[string][]byte
	failPut, failDelete bool
}

func (f *fakeObjectStore) Put(_ context.Context, key string, r io.ReadSeeker, _ int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, e := io.ReadAll(r)
	f.objects[key] = b
	if f.failPut {
		return fmt.Errorf("ambiguous PUT")
	}
	return e
}
func (f *fakeObjectStore) Get(_ context.Context, key string) (io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, ok := f.objects[key]
	if !ok {
		return nil, fmt.Errorf("missing")
	}
	return io.NopCloser(bytes.NewReader(append([]byte(nil), b...))), nil
}
func (f *fakeObjectStore) Delete(_ context.Context, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failDelete {
		return fmt.Errorf("delete failed")
	}
	delete(f.objects, key)
	return nil
}
func integrationService(t *testing.T) (*Service, *fakeObjectStore) {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("SOCIALWIRE_GO_TEST_DATABASE_URL is unset")
	}
	cfg, e := pgx.ParseConfig(dsn)
	if e != nil {
		t.Fatal(e)
	}
	admin := stdlib.OpenDB(*cfg)
	schema := fmt.Sprintf("socialdraft_test_%d", time.Now().UnixNano())
	if _, e = admin.Exec(`CREATE SCHEMA ` + schema); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { admin.Exec(`DROP SCHEMA ` + schema + ` CASCADE`); admin.Close() })
	cfg.RuntimeParams["search_path"] = schema
	db := stdlib.OpenDB(*cfg)
	db.SetMaxOpenConns(16)
	t.Cleanup(func() { db.Close() })
	_, file, _, _ := runtime.Caller(0)
	migration, e := os.ReadFile(filepath.Join(filepath.Dir(file), "../../../database/migrations/20261020233000_private_social_draft_assets.sql"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(string(migration)); e != nil {
		t.Fatal(e)
	}
	s, e := New(db, Config{Enabled: true, Endpoint: "https://s3.example", Bucket: "private", Region: "auto", AccessKeyID: "key", SecretAccessKey: "secret", StorageKey: base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))})
	if e != nil {
		t.Fatal(e)
	}
	f := &fakeObjectStore{objects: map[string][]byte{}}
	s.objects = f
	return s, f
}
func reserveInput(id string, b []byte) ReserveInput {
	return ReserveInput{AssetID: id, Name: "secret.vtt", ContentType: "text/vtt", ByteLength: int64(len(b)), SHA256: sum(b), Kind: "caption"}
}
func ready(t *testing.T, s *Service, owner, id string) Asset {
	t.Helper()
	b := []byte("WEBVTT\n\n00:00.000 --> 00:01.000\nprivate\n")
	in := reserveInput(id, b)
	if _, e := s.Reserve(context.Background(), owner, in); e != nil {
		t.Fatal(e)
	}
	a, e := s.Upload(context.Background(), owner, id, bytes.NewReader(b), int64(len(b)))
	if e != nil {
		t.Fatal(e)
	}
	return a
}

const ownerA = "did:plc:alice"
const ownerB = "did:plc:bob"
const assetA = "11111111-1111-4111-8111-111111111111"
const assetB = "22222222-2222-4222-8222-222222222222"
const draftA = "3l5hgbwxk3c2a"
const draftB = "3l5hgbwxk3c2b"

func TestPostgresLifecycle(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	a := ready(t, s, ownerA, assetA)
	if _, _, e := s.Download(ctx, ownerB, assetA); e != ErrNotFound {
		t.Fatal(e)
	}
	if _, e := s.PutManifest(ctx, ownerB, PutManifestInput{DraftID: draftA, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption"}}}); e != ErrNotFound {
		t.Fatal(e)
	}
	r, got, e := s.Download(ctx, ownerA, assetA)
	if e != nil {
		t.Fatal(e)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if got != a || sum(b) != a.SHA256 {
		t.Fatal("download mismatch")
	}
	in := reserveInput(assetA, b)
	if _, e = s.Reserve(ctx, ownerA, in); e != nil {
		t.Fatal(e)
	}
	in.Name = "changed"
	if _, e = s.Reserve(ctx, ownerA, in); e != ErrConflict {
		t.Fatal(e)
	}
	for _, d := range []string{draftA, draftB} {
		if _, e = s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: d, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption", Ref: "opaque"}}}); e != nil {
			t.Fatal(e)
		}
	}
	if _, e = s.DeleteManifest(ctx, ownerA, draftA, 0); e != ErrConflict {
		t.Fatal(e)
	}
	m, e := s.DeleteManifest(ctx, ownerA, draftA, 1)
	if e != nil || !m.Deleted || m.Revision != 2 {
		t.Fatalf("%+v %v", m, e)
	}
	if _, e = s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, ExpectedRevision: 1}); e != ErrConflict {
		t.Fatal(e)
	}
	s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()-interval '1 hour'`)
	if n, e := replica(s).Cleanup(ctx, 100); e != nil || n != 0 {
		t.Fatalf("referenced GC %d %v", n, e)
	}
	if r, _, e := s.Download(ctx, ownerA, assetA); e != nil {
		t.Fatal(e)
	} else {
		r.Close()
	}
	if _, e = s.DeleteManifest(ctx, ownerA, draftB, 1); e != nil {
		t.Fatal(e)
	}
	if _, _, e = s.Download(ctx, ownerA, assetA); e != ErrNotFound {
		t.Fatal(e)
	}
	f.failDelete = true
	if _, e = s.Cleanup(ctx, 10); e != ErrUnavailable {
		t.Fatal(e)
	}
	var attempts int
	if e = s.db.QueryRow(`SELECT attempts FROM private_social_draft_cleanup`).Scan(&attempts); e != nil || attempts != 1 {
		t.Fatalf("retry %d %v", attempts, e)
	}
	f.failDelete = false
	s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()`)
	if n, e := s.Cleanup(ctx, 10); n != 1 || e != nil {
		t.Fatalf("cleanup %d %v", n, e)
	}
	if len(f.objects) != 0 {
		t.Fatal("object remains")
	}
	var metadata []byte
	s.db.QueryRow(`SELECT metadata FROM private_social_draft_assets WHERE owner=$1`, ownerA).Scan(&metadata)
	if bytes.Contains(metadata, []byte("secret.vtt")) {
		t.Fatal("filename plaintext")
	}
}
func TestPostgresUploadFailures(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n\nprivate\n")
	in := reserveInput(assetA, b)
	if _, e := s.Reserve(ctx, ownerA, in); e != nil {
		t.Fatal(e)
	}
	if _, _, e := s.Download(ctx, ownerA, assetA); e != ErrUploadPending {
		t.Fatal(e)
	}
	for _, data := range [][]byte{b[:len(b)-1], append(append([]byte(nil), b...), 0), bytes.Repeat([]byte{'x'}, len(b))} {
		if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(data), int64(len(b))); e != ErrInvalid {
			t.Fatal(e)
		}
	}
	f.failPut = true
	if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b), int64(len(b))); e != ErrUnavailable {
		t.Fatal(e)
	}
	f.failPut = false
	if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b), int64(len(b))); e != nil {
		t.Fatal(e)
	}
	for key, value := range f.objects {
		value[len(value)/2] ^= 1
		f.objects[key] = value
	}
	if r, _, e := s.Download(ctx, ownerA, assetA); e != ErrUnavailable || r != nil {
		t.Fatalf("corruption %v", e)
	}
	// An unreferenced staging object expires, including ambiguous successful PUTs.
	s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()-interval '25 hours'`)
	if n, e := s.Cleanup(ctx, 1); n != 1 || e != nil {
		t.Fatalf("TTL %d %v", n, e)
	}
}
func TestPostgresQuotaAndCASConcurrency(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	var wg sync.WaitGroup
	var mu sync.Mutex
	ok, quota := 0, 0
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			in := ReserveInput{AssetID: fmt.Sprintf("%08x-1111-4111-8111-111111111111", i), Name: "large.png", ContentType: "image/png", Kind: "photo", ByteLength: MaxFileBytes, SHA256: sum(nil)}
			e := retryBusy(func() error { _, e := replica(s).Reserve(ctx, ownerA, in); return e })
			mu.Lock()
			defer mu.Unlock()
			switch e {
			case nil:
				ok++
			case ErrQuota:
				quota++
			default:
				t.Errorf("reserve: %v", e)
			}
		}(i)
	}
	wg.Wait()
	if ok != 10 || quota != 2 {
		t.Fatalf("quota successes=%d rejects=%d", ok, quota)
	}
	wins, conflicts := 0, 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e := retryBusy(func() error { _, e := replica(s).PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA}); return e })
			mu.Lock()
			defer mu.Unlock()
			switch e {
			case nil:
				wins++
			case ErrConflict:
				conflicts++
			default:
				t.Errorf("CAS %v", e)
			}
		}()
	}
	wg.Wait()
	if wins != 1 || conflicts != 7 {
		t.Fatalf("CAS wins=%d conflicts=%d", wins, conflicts)
	}
}

func TestPostgresCleanupReplicasAndImmutableIDs(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	// The same client UUID is legal in separate owner namespaces.
	ready(t, s, ownerA, assetA)
	ready(t, s, ownerB, assetA)
	for i := 0; i < 10; i++ {
		ready(t, s, fmt.Sprintf("did:plc:replica%d", i), assetA)
	}
	if _, e := s.db.Exec(`UPDATE private_social_draft_cleanup SET available_at=now()-interval '25 hours'`); e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	total := 0
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			n, e := replica(s).Cleanup(ctx, 100)
			if e != nil {
				t.Errorf("cleanup: %v", e)
			}
			mu.Lock()
			total += n
			mu.Unlock()
		}()
	}
	wg.Wait()
	if total != 12 || len(f.objects) != 0 {
		t.Fatalf("replica cleanup count=%d remaining=%d", total, len(f.objects))
	}
	b := []byte("WEBVTT\n\n00:00.000 --> 00:01.000\nprivate\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != ErrAssetRetired {
		t.Fatalf("deleted ID reused: %v", e)
	}
}

func TestPostgresPendingManifestAndTombstoneCAS(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	b := []byte("WEBVTT\n")
	if _, e := s.Reserve(ctx, ownerA, reserveInput(assetA, b)); e != nil {
		t.Fatal(e)
	}
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, Attachments: []ManifestRef{{AssetID: assetA, Role: "caption"}}}); e != ErrUploadPending {
		t.Fatal(e)
	}
	m, e := s.DeleteManifest(ctx, ownerA, draftA, 0)
	if e != nil || m.Revision != 1 || !m.Deleted {
		t.Fatalf("tombstone %+v %v", m, e)
	}
	if _, e := s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA}); e != ErrConflict {
		t.Fatal(e)
	}
	m, e = s.PutManifest(ctx, ownerA, PutManifestInput{DraftID: draftA, ExpectedRevision: 1})
	if e != nil || m.Revision != 2 || m.Deleted {
		t.Fatalf("restore %+v %v", m, e)
	}
}

func TestPostgresTemporaryFilesRemovedOnFailure(t *testing.T) {
	s, f := integrationService(t)
	ctx := context.Background()
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	b := []byte("WEBVTT\n\nprivate\n")
	in := reserveInput(assetA, b)
	if _, e := s.Reserve(ctx, ownerA, in); e != nil {
		t.Fatal(e)
	}
	if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b[:len(b)-1]), int64(len(b))); e != ErrInvalid {
		t.Fatal(e)
	}
	f.failPut = true
	if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b), int64(len(b))); e != ErrUnavailable {
		t.Fatal(e)
	}
	f.failPut = false
	if files, e := os.ReadDir(dir); e != nil || len(files) != 0 {
		t.Fatalf("upload leaked temp files: %d %v", len(files), e)
	}
	if _, e := s.Upload(ctx, ownerA, assetA, bytes.NewReader(b), int64(len(b))); e != nil {
		t.Fatal(e)
	}
	for key, value := range f.objects {
		f.objects[key] = value[:len(value)-1]
	}
	if _, _, e := s.Download(ctx, ownerA, assetA); e != ErrUnavailable {
		t.Fatal(e)
	}
	if files, e := os.ReadDir(dir); e != nil || len(files) != 0 {
		t.Fatalf("download leaked temp files: %d %v", len(files), e)
	}
}

func replica(s *Service) *Service { return &Service{db: s.db, gcm: s.gcm, objects: s.objects} }

// Busy admission and cross-replica NOWAIT are transient overload responses.
func retryBusy(fn func() error) error {
	deadline := time.Now().Add(5 * time.Second)
	for {
		e := fn()
		if e != ErrUnavailable || time.Now().After(deadline) {
			return e
		}
		time.Sleep(time.Millisecond)
	}
}
