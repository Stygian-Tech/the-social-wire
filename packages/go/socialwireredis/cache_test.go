package socialwireredis

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/sony/gobreaker/v2"
)

type fakeCommands struct {
	data    []byte
	deleted bool
	ttl     time.Duration
	err     error
}

func (f *fakeCommands) Get(context.Context, string) ([]byte, error) { return f.data, f.err }
func (f *fakeCommands) Set(_ context.Context, _ string, data []byte, ttl time.Duration) error {
	f.data = data
	f.ttl = ttl
	return f.err
}
func (f *fakeCommands) Delete(context.Context, []string) error { f.deleted = true; return f.err }
func TestSwiftCacheEnvelopeBoundaries(t *testing.T) {
	at := time.Unix(100, 0)
	commands := &fakeCommands{data: []byte(`{"schemaVersion":1,"cachedAt":100000,"freshUntil":110000,"hardExpiresAt":120000,"value":{"title":"cached"}}`)}
	client := NewCacheClient(commands)
	for _, test := range []struct {
		offset time.Duration
		state  LookupState
	}{{0, Fresh}, {10 * time.Second, Stale}, {20 * time.Second, Miss}} {
		v, err := LookupValue[map[string]string](context.Background(), client, "key", at.Add(test.offset))
		if err != nil || v.State != test.state {
			t.Fatalf("%v got %v %v", test.offset, v.State, err)
		}
	}
	if !commands.deleted {
		t.Fatal("expired envelope was not removed")
	}
}
func TestMalformedCacheIsMiss(t *testing.T) {
	for _, data := range []string{`{}`, `{"schemaVersion":2,"cachedAt":1,"freshUntil":2,"hardExpiresAt":999999,"value":0}`, `{"schemaVersion":1,"cachedAt":1,"freshUntil":2,"hardExpiresAt":999999}`, `not json`} {
		commands := &fakeCommands{data: []byte(data)}
		v, err := LookupValue[int](context.Background(), NewCacheClient(commands), "key", time.Unix(1, 0))
		if err != nil || v.State != Miss || !commands.deleted {
			t.Fatalf("malformed cache %s got %+v %v", data, v, err)
		}
	}
}
func TestCacheStoreTTLAndRoundTrip(t *testing.T) {
	commands := &fakeCommands{}
	client := NewCacheClient(commands)
	now := time.Unix(100, 0)
	if err := StoreValue(context.Background(), client, "key", "test", CachePolicy{time.Second, 10 * time.Second, .1}, now); err != nil {
		t.Fatal(err)
	}
	if commands.ttl < 10*time.Second || commands.ttl > 11*time.Second {
		t.Fatal("TTL out of bounds", commands.ttl)
	}
	value, err := LookupValue[string](context.Background(), client, "key", now)
	if err != nil || value.Envelope.Value != "test" {
		t.Fatal(value, err)
	}
}
func TestCircuitBreakerIgnoresOlderSuccess(t *testing.T) {
	breaker := NewCircuitBreaker()
	started, finish := make(chan struct{}), make(chan struct{})
	var wg sync.WaitGroup
	wg.Go(func() {
		_, err := breaker.Execute(func() ([]byte, error) {
			close(started)
			<-finish
			return nil, nil
		})
		if err != nil {
			t.Error(err)
		}
	})
	<-started
	for range 3 {
		_, _ = breaker.Execute(func() ([]byte, error) { return nil, errors.New("unavailable") })
	}
	close(finish)
	wg.Wait()
	if breaker.State() != gobreaker.StateOpen {
		t.Fatal("older success closed open circuit")
	}
}
func TestCircuitBreakerOneConcurrentRecoveryProbe(t *testing.T) {
	breaker := gobreaker.NewCircuitBreaker[[]byte](gobreaker.Settings{
		MaxRequests: 1, Timeout: time.Millisecond,
		ReadyToTrip: func(gobreaker.Counts) bool { return true },
	})
	_, _ = breaker.Execute(func() ([]byte, error) { return nil, errors.New("unavailable") })
	time.Sleep(2 * time.Millisecond)
	started, finish := make(chan struct{}), make(chan struct{})
	var wg sync.WaitGroup
	wg.Go(func() {
		_, err := breaker.Execute(func() ([]byte, error) { close(started); <-finish; return nil, nil })
		if err != nil {
			t.Error(err)
		}
	})
	<-started
	for range 20 {
		_, err := breaker.Execute(func() ([]byte, error) { t.Error("additional recovery probe executed"); return nil, nil })
		if !errors.Is(err, gobreaker.ErrTooManyRequests) {
			t.Fatal(err)
		}
	}
	close(finish)
	wg.Wait()
	if breaker.State() != gobreaker.StateClosed {
		t.Fatal("successful probe did not close circuit")
	}
}
func TestCacheErrorsOpenCircuit(t *testing.T) {
	commands := &fakeCommands{err: errors.New("unavailable")}
	client := NewCacheClient(commands)
	for range 3 {
		_, _ = LookupValue[string](context.Background(), client, "key", time.Now())
	}
	_, err := LookupValue[string](context.Background(), client, "key", time.Now())
	if !errors.Is(err, ErrCircuitOpen) {
		t.Fatal(err)
	}
}
func TestNamespaceHidesIdentifiers(t *testing.T) {
	key := NewKeyNamespace("Production", "v1").Key("wire", []string{"und"}, []string{"did:plc:private"})
	if key != "sw:production:v1:wire:und:"+Digest("did:plc:private") {
		t.Fatal(key)
	}
}
