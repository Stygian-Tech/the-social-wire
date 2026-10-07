package socialwireredis

// Maintains the Swift-compatible JSON cache envelope in epoch milliseconds. Reads
// distinguish fresh, stale, and miss; malformed, unknown-version, or hard-expired entries
// are deleted best-effort. Writes jitter hard TTL only and run through the shared circuit
// breaker.

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"math/rand/v2"
	"time"

	"github.com/sony/gobreaker/v2"
)

var ErrCircuitOpen = errors.New("redis cache circuit open")

// Commands is the cache transport boundary; missing Get results are nil data with no
// error.
type Commands interface {
	Get(context.Context, string) ([]byte, error)
	Set(context.Context, string, []byte, time.Duration) error
	Delete(context.Context, []string) error
}

// CachePolicy sets fresh lifetime, hard lifetime, and optional positive hard-TTL jitter up
// to ten percent.
type CachePolicy struct {
	FreshDuration, HardDuration time.Duration
	MaximumJitterFraction       float64
}

// Validate rejects values that violate this type’s documented bounds before they are used.
func (policy CachePolicy) Validate() error {
	if policy.FreshDuration <= 0 || policy.HardDuration < policy.FreshDuration || math.IsNaN(policy.MaximumJitterFraction) || policy.MaximumJitterFraction < 0 || policy.MaximumJitterFraction > .1 {
		return errors.New("invalid cache policy")
	}
	return nil
}

// Envelope stores schema and freshness metadata with a generic cached value.
// Timestamp fields retain Swift JSONEncoder.millisecondsSince1970 compatibility.
type Envelope[T any] struct {
	SchemaVersion *int     `json:"schemaVersion"`
	CachedAt      *float64 `json:"cachedAt"`
	FreshUntil    *float64 `json:"freshUntil"`
	HardExpiresAt *float64 `json:"hardExpiresAt"`
	Value         T        `json:"value"`
}

// LookupState distinguishes a fresh value, usable stale value, and absent/unusable cache
// entry.
type LookupState string

const (
	Miss  LookupState = "miss"
	Fresh LookupState = "fresh"
	Stale LookupState = "stale"
)

// Lookup carries an envelope for fresh/stale results; misses do not carry a usable value.
type Lookup[T any] struct {
	State    LookupState
	Envelope *Envelope[T]
}

// CacheClient pairs cache transport with a shared concurrent circuit breaker; it does not
// own transport shutdown.
type CacheClient struct {
	Commands Commands
	Breaker  *gobreaker.CircuitBreaker[[]byte]
}

// NewCacheClient wraps supplied commands with the standard three-failure circuit breaker.
func NewCacheClient(commands Commands) *CacheClient {
	return &CacheClient{commands, NewCircuitBreaker()}
}

// LookupValue returns fresh/stale/miss according to supplied time and removes unusable
// envelopes best-effort.
func LookupValue[T any](ctx context.Context, client *CacheClient, key string, now time.Time) (Lookup[T], error) {
	miss := Lookup[T]{State: Miss}
	data, err := client.Breaker.Execute(func() ([]byte, error) { return client.Commands.Get(ctx, key) })
	if err != nil {
		if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
			return miss, ErrCircuitOpen
		}
		return miss, err
	}
	if data == nil {
		return miss, nil
	}
	var envelope Envelope[T]
	var raw map[string]json.RawMessage
	malformed := json.Unmarshal(data, &envelope) != nil || json.Unmarshal(data, &raw) != nil || envelope.SchemaVersion == nil || envelope.CachedAt == nil || envelope.FreshUntil == nil || envelope.HardExpiresAt == nil || raw["value"] == nil
	milliseconds := float64(now.UnixNano()) / 1e6
	if malformed || (envelope.SchemaVersion != nil && *envelope.SchemaVersion != 1) || (envelope.HardExpiresAt != nil && milliseconds >= *envelope.HardExpiresAt) {
		_ = client.Commands.Delete(ctx, []string{key})
		return miss, nil
	}
	state := Stale
	if milliseconds < *envelope.FreshUntil {
		state = Fresh
	}
	return Lookup[T]{state, &envelope}, nil
}

// StoreValue writes a v1 envelope with positive hard-expiry jitter and matching
// millisecond transport TTL.
func StoreValue[T any](ctx context.Context, client *CacheClient, key string, value T, policy CachePolicy, now time.Time) error {
	if err := policy.Validate(); err != nil {
		return err
	}
	jitter := float64(policy.HardDuration) * rand.Float64() * policy.MaximumJitterFraction
	duration := policy.HardDuration + time.Duration(jitter)
	version := 1
	cached := float64(now.UnixNano()) / 1e6
	fresh := cached + float64(policy.FreshDuration)/1e6
	hard := cached + float64(duration)/1e6
	data, err := json.Marshal(Envelope[T]{&version, &cached, &fresh, &hard, value})
	if err != nil {
		return err
	}
	_, err = client.Breaker.Execute(func() ([]byte, error) {
		return nil, client.Commands.Set(ctx, key, data, max(time.Millisecond, duration.Truncate(time.Millisecond)))
	})
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return ErrCircuitOpen
	}
	return err
}
