package corpuscore

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"math"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

type payloadEntry struct {
	Revision string          `json:"revision"`
	Value    json.RawMessage `json:"value"`
}
type payloadFlight struct {
	done chan struct{}
	data []byte
	err  error
}
type PayloadCache struct {
	Client              *socialwireredis.CacheClient
	Namespace           socialwireredis.KeyNamespace
	Domain              string
	MaximumPayloadBytes int
	mu                  sync.Mutex
	flights             map[string]*payloadFlight
	counts              map[string]int
	lastReport          time.Time
}

func NewPayloadCache(commands socialwireredis.Commands, environment, domain string) *PayloadCache {
	if domain == "" {
		domain = "wire-public-payload"
	}
	return &PayloadCache{Client: socialwireredis.NewCacheClient(commands), Namespace: socialwireredis.NewKeyNamespace(environment, "corpus-payload-v1"), Domain: domain, MaximumPayloadBytes: 1 << 20, flights: map[string]*payloadFlight{}, counts: map[string]int{}}
}
func (c *PayloadCache) record(outcome string, scope []string, now time.Time) {
	domain := "other"
	if len(scope) > 0 {
		switch scope[0] {
		case "feed", "edition", "item", "catalog":
			domain = scope[0]
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[domain+"_"+outcome]++
	if c.lastReport.IsZero() {
		c.lastReport = now
		return
	}
	if now.Sub(c.lastReport) >= time.Minute {
		slog.Info("Wire public payload cache minute totals", "counts", c.counts)
		c.counts = map[string]int{}
		c.lastReport = now
	}
}
func (c *PayloadCache) Statistics() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	result := map[string]int{}
	for key, value := range c.counts {
		result[key] = value
	}
	return result
}
func GenerationLifetime(expires, now time.Time) time.Duration {
	return max(0, min(10*time.Minute, expires.Sub(now)))
}
func cachedValue[T any](ctx context.Context, c *PayloadCache, scope []string, revision string, now time.Time, lifetime time.Duration, current func(context.Context) (string, error), validates func(T) bool, load func(context.Context) (T, error)) (T, error) {
	if c == nil {
		return load(ctx)
	}
	key := c.Namespace.Key(c.Domain, nil, scope)
	lookup, err := socialwireredis.LookupValue[payloadEntry](ctx, c.Client, key, now)
	if err != nil {
		c.record("redis_error", scope, now)
	} else if lookup.State == socialwireredis.Fresh && lookup.Envelope.Value.Revision == revision {
		if value, e := decodePayload[T](lookup.Envelope.Value.Value); e == nil && (validates == nil || validates(value)) {
			c.record("hit", scope, now)
			return value, nil
		}
	}
	c.record("miss", scope, now)
	flightKey := key + ":" + socialwireredis.Digest(revision)
	c.mu.Lock()
	if previous := c.flights[flightKey]; previous != nil {
		c.mu.Unlock()
		c.record("coalesced", scope, now)
		select {
		case <-ctx.Done():
			var zero T
			return zero, ctx.Err()
		case <-previous.done:
			if previous.err != nil {
				var zero T
				return zero, previous.err
			}
			return decodePayload[T](previous.data)
		}
	}
	if len(c.flights) >= 128 {
		c.mu.Unlock()
		return load(ctx)
	}
	flight := &payloadFlight{done: make(chan struct{})}
	c.flights[flightKey] = flight
	c.mu.Unlock()
	defer func() { c.mu.Lock(); delete(c.flights, flightKey); close(flight.done); c.mu.Unlock() }()
	value, err := load(ctx)
	if err != nil {
		flight.err = err
		return value, err
	}
	data, err := encodePayload(value)
	if err != nil {
		flight.err = err
		return value, err
	}
	flight.data = data
	switch {
	case len(data) > c.MaximumPayloadBytes:
		c.record("oversized", scope, now)
	case lifetime <= 0:
		c.record("expired", scope, now)
	case validates != nil && !validates(value):
		c.record("membership_changed", scope, now)
	default:
		latest, e := current(ctx)
		if e != nil {
			c.record("revision_error", scope, now)
		} else if latest != revision {
			c.record("revision_changed", scope, now)
		} else {
			policy := socialwireredis.CachePolicy{FreshDuration: lifetime, HardDuration: lifetime}
			if e := socialwireredis.StoreValue(ctx, c.Client, key, payloadEntry{revision, data}, policy, now); e != nil {
				c.record("redis_error", scope, now)
			} else {
				c.record("fill", scope, now)
			}
		}
	}
	return value, nil
}

// The shared Swift Redis encoder uses milliseconds for every typed Date, including
// payloads nested inside the generic envelope. HTTP responses continue to use ISO8601.
func encodePayload[T any](value T) ([]byte, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var raw any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err = decoder.Decode(&raw); err != nil {
		return nil, err
	}
	raw = payloadDates(raw, reflect.TypeFor[T](), true)
	return json.Marshal(raw)
}
func decodePayload[T any](data []byte) (T, error) {
	var result T
	var raw any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&raw); err != nil {
		return result, err
	}
	raw = payloadDates(raw, reflect.TypeFor[T](), false)
	data, err := json.Marshal(raw)
	if err == nil {
		err = json.Unmarshal(data, &result)
	}
	return result, err
}
func payloadDates(raw any, t reflect.Type, encode bool) any {
	if t == nil || raw == nil {
		return raw
	}
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == reflect.TypeFor[time.Time]() {
		if encode {
			if text, ok := raw.(string); ok {
				if date, err := time.Parse(time.RFC3339Nano, text); err == nil {
					return float64(date.UnixNano()) / 1e6
				}
			}
		} else if number, ok := raw.(json.Number); ok {
			value, err := number.Float64()
			if err == nil {
				whole := int64(value)
				nanos := (whole%1000)*1e6 + int64(math.Round((value-float64(whole))*1e6))
				return time.Unix(whole/1000, nanos).UTC().Format(time.RFC3339Nano)
			}
		}
		return raw
	}
	switch t.Kind() {
	case reflect.Struct:
		if object, ok := raw.(map[string]any); ok {
			for i := 0; i < t.NumField(); i++ {
				field := t.Field(i)
				tag := strings.Split(field.Tag.Get("json"), ",")[0]
				if tag == "-" || field.PkgPath != "" {
					continue
				}
				if field.Anonymous && tag == "" {
					payloadDates(raw, field.Type, encode)
					continue
				}
				if tag == "" {
					tag = field.Name
				}
				if value, exists := object[tag]; exists {
					object[tag] = payloadDates(value, field.Type, encode)
				}
			}
		}
	case reflect.Slice, reflect.Array:
		if values, ok := raw.([]any); ok {
			for i, value := range values {
				values[i] = payloadDates(value, t.Elem(), encode)
			}
		}
	case reflect.Map:
		if values, ok := raw.(map[string]any); ok {
			for key, value := range values {
				values[key] = payloadDates(value, t.Elem(), encode)
			}
		}
	}
	return raw
}
