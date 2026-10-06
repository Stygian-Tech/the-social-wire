package socialwireredis

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

type Commands interface {
	Get(context.Context, string) ([]byte, error)
	Set(context.Context, string, []byte, time.Duration) error
	Delete(context.Context, []string) error
}
type CachePolicy struct {
	FreshDuration, HardDuration time.Duration
	MaximumJitterFraction       float64
}

func (p CachePolicy) Validate() error {
	if p.FreshDuration <= 0 || p.HardDuration < p.FreshDuration || math.IsNaN(p.MaximumJitterFraction) || p.MaximumJitterFraction < 0 || p.MaximumJitterFraction > .1 {
		return errors.New("invalid cache policy")
	}
	return nil
}

// Milliseconds retains the existing JSONEncoder.millisecondsSince1970 format.
type Envelope[T any] struct {
	SchemaVersion *int     `json:"schemaVersion"`
	CachedAt      *float64 `json:"cachedAt"`
	FreshUntil    *float64 `json:"freshUntil"`
	HardExpiresAt *float64 `json:"hardExpiresAt"`
	Value         T        `json:"value"`
}
type LookupState string

const (
	Miss  LookupState = "miss"
	Fresh LookupState = "fresh"
	Stale LookupState = "stale"
)

type Lookup[T any] struct {
	State    LookupState
	Envelope *Envelope[T]
}
type CacheClient struct {
	Commands Commands
	Breaker  *gobreaker.CircuitBreaker[[]byte]
}

func NewCacheClient(commands Commands) *CacheClient {
	return &CacheClient{commands, NewCircuitBreaker()}
}
func LookupValue[T any](ctx context.Context, c *CacheClient, key string, now time.Time) (Lookup[T], error) {
	miss := Lookup[T]{State: Miss}
	data, err := c.Breaker.Execute(func() ([]byte, error) { return c.Commands.Get(ctx, key) })
	if err != nil {
		if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
			return miss, ErrCircuitOpen
		}
		return miss, err
	}
	if data == nil {
		return miss, nil
	}
	var e Envelope[T]
	var raw map[string]json.RawMessage
	malformed := json.Unmarshal(data, &e) != nil || json.Unmarshal(data, &raw) != nil || e.SchemaVersion == nil || e.CachedAt == nil || e.FreshUntil == nil || e.HardExpiresAt == nil || raw["value"] == nil
	milliseconds := float64(now.UnixNano()) / 1e6
	if malformed || (e.SchemaVersion != nil && *e.SchemaVersion != 1) || (e.HardExpiresAt != nil && milliseconds >= *e.HardExpiresAt) {
		_ = c.Commands.Delete(ctx, []string{key})
		return miss, nil
	}
	state := Stale
	if milliseconds < *e.FreshUntil {
		state = Fresh
	}
	return Lookup[T]{state, &e}, nil
}
func StoreValue[T any](ctx context.Context, c *CacheClient, key string, value T, policy CachePolicy, now time.Time) error {
	if e := policy.Validate(); e != nil {
		return e
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
	_, err = c.Breaker.Execute(func() ([]byte, error) {
		return nil, c.Commands.Set(ctx, key, data, max(time.Millisecond, duration.Truncate(time.Millisecond)))
	})
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return ErrCircuitOpen
	}
	return err
}
