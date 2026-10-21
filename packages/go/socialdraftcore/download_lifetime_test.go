package socialdraftcore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestTemporaryReaderConcurrentCloseAndCancelReleaseOnce(t *testing.T) {
	f, e := tempFile()
	if e != nil {
		t.Fatal(e)
	}
	name := f.Name()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var releases atomic.Int32
	r := newTemporaryReader(ctx, f, func() { releases.Add(1) })
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cancel()
			if e := r.Close(); e != nil {
				t.Errorf("close: %v", e)
			}
		}()
	}
	wg.Wait()
	if releases.Load() != 1 {
		t.Fatalf("released %d times", releases.Load())
	}
	if _, e = os.Stat(name); !os.IsNotExist(e) {
		t.Fatalf("temporary file remains: %v", e)
	}
}

func TestTemporaryReaderAlreadyCancelledContext(t *testing.T) {
	f, e := tempFile()
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	released := make(chan struct{})
	r := newTemporaryReader(ctx, f, func() { close(released) })
	defer r.Close()
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("abandoned reader not reclaimed")
	}
	if _, e = os.Stat(f.Name()); !os.IsNotExist(e) {
		t.Fatal("cancelled reader left a temporary file")
	}
}

func TestPostgresDownloadAdmissionRetainedUntilCloseOrCancel(t *testing.T) {
	for _, cancelReader := range []bool{false, true} {
		name := "Close"
		if cancelReader {
			name = "Cancel"
		}
		t.Run(name, func(t *testing.T) {
			s, _ := integrationService(t)
			ready(t, s, ownerA, assetA)
			dir := t.TempDir()
			t.Setenv("TMPDIR", dir)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			r, _, e := s.Download(ctx, ownerA, assetA)
			if e != nil {
				t.Fatal(e)
			}
			defer r.Close()
			path := r.(*temporaryReader).file.Name()
			if _, e = os.Stat(path); e != nil {
				t.Fatalf("no streaming file: %v", e)
			}
			before := s.db.Stats()
			if before.InUse != 0 {
				t.Fatalf("reader retained %d database connections", before.InUse)
			}
			if extra, _, e := s.Download(context.Background(), ownerA, assetA); e != ErrUnavailable {
				if extra != nil {
					extra.Close()
				}
				t.Fatalf("streaming admission was released: %v", e)
			}
			if after := s.db.Stats(); after.InUse != 0 || after.WaitCount != before.WaitCount {
				t.Fatalf("reader waiter acquired/waited for a connection: %+v", after)
			}
			// A different replica can acquire the same owner's DB lock while streaming.
			if _, e := replica(s).Manifest(context.Background(), ownerA, draftA); e != ErrNotFound {
				t.Fatalf("reader retained database owner lock: %v", e)
			}
			if cancelReader {
				cancel()
				deadline := time.NewTimer(2 * time.Second)
				defer deadline.Stop()
				tick := time.NewTicker(time.Millisecond)
				defer tick.Stop()
				for {
					s.admission.mu.Lock()
					active := s.admission.active
					s.admission.mu.Unlock()
					if active == 0 {
						break
					}
					select {
					case <-tick.C:
					case <-deadline.C:
						t.Fatal("cancel did not release reader admission")
					}
				}
			} else {
				if e = r.Close(); e != nil {
					t.Fatal(e)
				}
			}
			if _, e = os.Stat(path); !os.IsNotExist(e) {
				t.Fatalf("plaintext file remains after cleanup: %v", e)
			}
			if _, e = r.Read(make([]byte, 1)); !errors.Is(e, os.ErrClosed) {
				t.Fatalf("reader not closed: %v", e)
			}
			if s.db.Stats().InUse != 0 {
				t.Fatal("cleanup retained a database connection")
			}
			next, _, e := s.Download(context.Background(), ownerA, assetA)
			if e != nil {
				t.Fatalf("admission not reclaimed: %v", e)
			}
			defer next.Close()
			// An old Close must not release a newer reader's slot for this owner.
			if e = r.Close(); e != nil {
				t.Fatal(e)
			}
			if extra, _, e := s.Download(context.Background(), ownerA, assetA); e != ErrUnavailable {
				if extra != nil {
					extra.Close()
				}
				t.Fatalf("old Close released newer admission: %v", e)
			}
			if e = next.Close(); e != nil {
				t.Fatal(e)
			}
			files, e := os.ReadDir(dir)
			if e != nil || len(files) != 0 {
				t.Fatalf("remaining temporary files=%d error=%v", len(files), e)
			}
		})
	}
}

func TestPostgresDownloadLifetimeBoundsTotalTemporaryFiles(t *testing.T) {
	s, _ := integrationService(t)
	ctx := context.Background()
	owners := make([]string, 5)
	for i := range owners {
		owners[i] = fmt.Sprintf("did:plc:download%d", i)
		ready(t, s, owners[i], assetA)
	}
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	var readers []io.ReadCloser
	for i := 0; i < 4; i++ {
		r, _, e := s.Download(ctx, owners[i], assetA)
		if e != nil {
			t.Fatal(e)
		}
		readers = append(readers, r)
		t.Cleanup(func() { r.Close() })
	}
	if r, _, e := s.Download(ctx, owners[4], assetA); e != ErrUnavailable {
		if r != nil {
			r.Close()
		}
		t.Fatalf("total streaming budget exceeded: %v", e)
	}
	if files, e := os.ReadDir(dir); e != nil || len(files) != 4 {
		t.Fatalf("streaming files=%d error=%v", len(files), e)
	}
	if s.db.Stats().InUse != 0 {
		t.Fatal("slow readers retain database connections")
	}
	if e := readers[0].Close(); e != nil {
		t.Fatal(e)
	}
	r, _, e := s.Download(ctx, owners[4], assetA)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	if files, e := os.ReadDir(dir); e != nil || len(files) != 4 {
		t.Fatalf("replacement files=%d error=%v", len(files), e)
	}
}
