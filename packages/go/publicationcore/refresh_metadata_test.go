package publicationcore

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type refreshPageRepo struct {
	repoFixture
	mu      sync.Mutex
	calls   map[refreshPageKey]int
	active  int
	started chan struct{}
	release <-chan struct{}
}

func (r *refreshPageRepo) ListRecords(ctx context.Context, did, collection, cursor string, limit int, reverse bool) (gatewaycore.RepoPage, error) {
	r.mu.Lock()
	if r.calls == nil {
		r.calls = map[refreshPageKey]int{}
	}
	r.calls[refreshPageKey{did, collection, cursor, limit, reverse}]++
	r.active++
	r.mu.Unlock()
	defer func() { r.mu.Lock(); r.active--; r.mu.Unlock() }()
	if r.started != nil {
		r.started <- struct{}{}
	}
	if r.release != nil {
		select {
		case <-ctx.Done():
			return gatewaycore.RepoPage{}, ctx.Err()
		case <-r.release:
		}
	}
	return gatewaycore.RepoPage{}, nil
}

func TestRefreshMetadataPageIdentity(t *testing.T) {
	r := &refreshPageRepo{}
	metadata := newRefreshMetadata(r)
	keys := []refreshPageKey{
		{"did:plc:a", "site.standard.publication", "", 50, true},
		{"did:plc:b", "site.standard.publication", "", 50, true},
		{"did:plc:a", "app.offprint.publication", "", 50, true},
		{"did:plc:a", "site.standard.publication", "next", 50, true},
		{"did:plc:a", "site.standard.publication", "", 1, true},
		{"did:plc:a", "site.standard.publication", "", 50, false},
	}
	var wg sync.WaitGroup
	for _, key := range keys {
		for i := 0; i < 25; i++ {
			wg.Add(1)
			go func(key refreshPageKey) {
				defer wg.Done()
				if _, err := metadata.ListRecords(context.Background(), key.did, key.collection, key.cursor, key.limit, key.reverse); err != nil {
					t.Error(err)
				}
			}(key)
		}
	}
	wg.Wait()
	if len(r.calls) != len(keys) {
		t.Fatalf("page keys collided: %v", r.calls)
	}
	for key, calls := range r.calls {
		if calls != 1 {
			t.Fatalf("%+v calls=%d", key, calls)
		}
	}
}

func TestRefreshMetadataCanceledPageWaiterDoesNotCancelOwner(t *testing.T) {
	release := make(chan struct{})
	r := &refreshPageRepo{started: make(chan struct{}, 1), release: release}
	metadata := newRefreshMetadata(r)
	done := make(chan error, 1)
	go func() {
		_, err := metadata.ListRecords(context.Background(), "did:plc:a", "site.standard.publication", "", 50, true)
		done <- err
	}()
	select {
	case <-r.started:
	case <-time.After(5 * time.Second):
		t.Fatal("owner did not start")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := metadata.ListRecords(ctx, "did:plc:a", "site.standard.publication", "", 50, true); !errors.Is(err, context.Canceled) {
		t.Fatalf("waiter err=%v", err)
	}
	select {
	case err := <-done:
		t.Fatalf("waiter ended owner: %v", err)
	default:
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if r.active != 0 || len(r.calls) != 1 {
		t.Fatalf("owner not joined: active=%d calls=%v", r.active, r.calls)
	}
}

func TestRefreshCancelsAndJoinsSiblingPageReads(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := &refreshPageRepo{started: make(chan struct{}, 25), release: make(chan struct{})}
	metadata := newRefreshMetadata(r)
	discovery := DiscoveryContext{ViewerDID: "viewer", refresh: metadata}
	for i := 0; i < 25; i++ {
		id := "at://did:plc:a/site.standard.publication/" + string(rune('a'+i))
		metadata.remember(record(id, map[string]any{"site": "https://site.invalid"}))
		discovery.UniqueRows = append(discovery.UniqueRows, DiscoveredRow{PublicationID: id, AuthorDID: "did:plc:a"})
	}
	s := NewService(nil, r, nil)
	defer s.Close()
	done := make(chan error, 1)
	go func() { _, err := s.BuildSidebar(ctx, discovery, "full", true); done <- err }()
	select {
	case <-r.started:
	case <-time.After(5 * time.Second):
		t.Fatal("sibling read did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("scope workers not joined")
	}
	if r.active != 0 || len(s.rows) != 0 {
		t.Fatalf("canceled scopes survived: active=%d rows=%v", r.active, s.rows)
	}
	for key, calls := range r.calls {
		if calls != 1 {
			t.Fatalf("canceled page duplicated: %+v calls=%d", key, calls)
		}
	}
}
