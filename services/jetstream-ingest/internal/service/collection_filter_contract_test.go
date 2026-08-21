package service

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
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
