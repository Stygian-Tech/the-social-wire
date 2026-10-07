package gatewaycore

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestAuthenticationSharedFetchJoinsAtShutdown(t *testing.T) {
	life := NewAuthLifetime(context.Background())
	started := make(chan struct{})
	done := make(chan struct{})
	client := &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	verifier := &TokenVerifier{Client: client, Lifetime: life}
	go func() {
		defer close(done)
		verifier.cachedFetch(context.Background(), "https://issuer.valid/keys", 1024, false)
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := life.Close(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("waiter not joined")
	}
	if _, _, err := verifier.cachedFetch(context.Background(), "https://issuer.valid/other", 1024, false); err == nil {
		t.Fatal("work started after shutdown")
	}
}
