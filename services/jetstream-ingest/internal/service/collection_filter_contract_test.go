package service

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"sync"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
)

func TestPinnedJetstreamClientForwardsWireCollectionsOnLiveRequest(t *testing.T) {
	type capturedRequest struct {
		path  string
		query url.Values
	}
	requests := make(chan capturedRequest, 4)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		select {
		case requests <- capturedRequest{path: request.URL.Path, query: request.URL.Query()}:
		default:
		}
		http.Error(writer, "contract probe", http.StatusBadRequest)
	}))
	defer server.Close()

	client, err := jetstream.Subscribe(
		server.URL,
		jetstream.WithCollections(config.WireCollections),
		jetstream.WithLiveCursor(0),
		jetstream.WithZstdCompression(false),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for range client.Events(ctx) {
		}
	}()

	select {
	case captured := <-requests:
		got := captured.query["collections"]
		for _, collection := range config.WireCollections {
			if !slices.Contains(got, collection) {
				t.Fatalf("live request %s omitted %q: %v", captured.path, collection, got)
			}
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for the pinned Jetstream client request")
	}

	cancel()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("Jetstream client did not stop after cancellation")
	}
}

func TestPinnedJetstreamClientBoundsSnapshotWithoutOpeningLiveTail(t *testing.T) {
	type planInput struct {
		AfterSeq    int64    `json:"afterSeq"`
		BeforeSeq   int64    `json:"beforeSeq"`
		Collections []string `json:"collections"`
	}
	var lock sync.Mutex
	var captured planInput
	var paths []string
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		lock.Lock()
		paths = append(paths, request.URL.Path)
		lock.Unlock()
		if request.URL.Path != "/xrpc/network.bsky.jetstream.planSnapshot" {
			http.Error(writer, "bounded snapshot must not open a live tail", http.StatusBadRequest)
			return
		}
		if err := json.NewDecoder(request.Body).Decode(&captured); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"plannedThroughSeq": 200,
			"sealedTipSeq":      200,
			"segments":          []any{},
			"stats": map[string]int{
				"segmentsExamined": 0, "segmentsMatched": 0, "blocksMatched": 0, "entries": 0,
			},
		})
	}))
	defer server.Close()

	before := uint64(200)
	cfg := config.Config{ReplayBeforeSeq: &before, ReplaySnapshotOnly: true}
	options := []jetstream.Option{
		jetstream.WithCollections(config.WireCollections),
		jetstream.WithAPIKey("contract-test-key"),
		jetstream.WithZstdCompression(false),
	}
	options = append(options, replayOptions(cfg, 100)...)
	client, err := jetstream.Subscribe(server.URL, options...)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	for _, streamErr := range client.Events(context.Background()) {
		if streamErr != nil {
			t.Fatal(streamErr)
		}
	}

	if captured.AfterSeq != 100 || captured.BeforeSeq != 200 {
		t.Fatalf("snapshot bounds = (%d,%d], want (100,200]", captured.AfterSeq, captured.BeforeSeq)
	}
	for _, collection := range config.WireCollections {
		if !slices.Contains(captured.Collections, collection) {
			t.Fatalf("snapshot plan omitted %q: %v", collection, captured.Collections)
		}
	}
	lock.Lock()
	defer lock.Unlock()
	if len(paths) != 1 || paths[0] != "/xrpc/network.bsky.jetstream.planSnapshot" {
		t.Fatalf("bounded snapshot requests = %v", paths)
	}
}
