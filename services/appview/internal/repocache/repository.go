// Package repocache keeps PDS resolution disposable and shared across App View reads.
package repocache

import (
	"context"
	"errors"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

type entry struct {
	endpoint    string
	fresh, hard time.Time
}
type localLease struct {
	owner   string
	expires time.Time
}
type Repository struct {
	*gatewaycore.RepoClient
	base      *gatewaycore.RepoClient
	redis     redis.Cmdable
	cache     *socialwireredis.CacheClient
	namespace socialwireredis.KeyNamespace
	mu        sync.Mutex
	entries   map[string]entry
	leases    map[string]localLease
	Now       func() time.Time
}

// New does not own either HTTP or Redis transport. RepoClient is the cached clone
// for consumers requiring the concrete shared reader type; the original stays unchanged.
func New(base *gatewaycore.RepoClient, commands redis.Cmdable, environment string) *Repository {
	// Hosts commonly pass an optional *redis.Client through the command interface.
	if commands != nil && reflect.ValueOf(commands).Kind() == reflect.Pointer && reflect.ValueOf(commands).IsNil() {
		commands = nil
	}

	r := &Repository{base: base.WithPDSResolver(nil), redis: commands, namespace: socialwireredis.NewKeyNamespace(environment, "v1"), entries: map[string]entry{}, leases: map[string]localLease{}, Now: time.Now}
	if commands != nil {
		r.cache = socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: commands})
	}
	r.RepoClient = base.WithPDSResolver(r.resolve)
	return r
}
func (r *Repository) resolve(ctx context.Context, did string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if len(did) < 4 || did[:4] != "did:" {
		return "", gatewaycore.ErrAuthentication
	}
	now := r.Now()
	state, endpoint, err := r.lookup(ctx, did, now)
	owner := ""
	if err == nil {
		if state == socialwireredis.Fresh {
			return cachedEndpoint(endpoint)
		}
		owner, err = r.acquire(ctx, did, now)
		if err == nil && owner == "" {
			if state == socialwireredis.Stale {
				return cachedEndpoint(endpoint)
			}
			for range 5 {
				timer := time.NewTimer(50 * time.Millisecond)
				select {
				case <-ctx.Done():
					timer.Stop()
					return "", ctx.Err()
				case <-timer.C:
				}
				contender, value, lookupErr := r.lookup(ctx, did, r.Now())
				if lookupErr != nil {
					break
				}
				if contender != socialwireredis.Miss {
					return cachedEndpoint(value)
				}
			}
		}
	}
	if owner != "" {
		defer r.release(did, owner)
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	work, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	endpoint, err = r.base.ResolvePDS(work, did)
	if err != nil {
		// Throttling, outages, canceled requests, and transport errors are never absence evidence.
		if errors.Is(err, gatewaycore.ErrAuthentication) {
			_ = r.store(ctx, did, "", r.Now())
		}
		return "", err
	}
	endpoint, err = cachedEndpoint(endpoint)
	if err != nil {
		_ = r.store(ctx, did, "", r.Now())
		return "", err
	}
	_ = r.store(ctx, did, endpoint, r.Now())
	return endpoint, nil
}
func cachedEndpoint(endpoint string) (string, error) {
	if endpoint == "" {
		return "", gatewaycore.ErrAuthentication
	}
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(endpoint, "#") {
		return "", gatewaycore.ErrAuthentication
	}
	return gatewaycore.NormalizePublicRemoteBase(endpoint)
}
func (r *Repository) lookup(ctx context.Context, did string, now time.Time) (socialwireredis.LookupState, string, error) {
	if r.cache != nil {
		result, err := socialwireredis.LookupValue[storedResolution](ctx, r.cache, r.namespace.Key("pds-resolution", nil, []string{did}), now)
		if err != nil || result.State == socialwireredis.Miss {
			return socialwireredis.Miss, "", err
		}
		return result.State, result.Envelope.Value.Endpoint, nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	value, ok := r.entries[did]
	if !ok || !now.Before(value.hard) {
		delete(r.entries, did)
		return socialwireredis.Miss, "", nil
	}
	if now.Before(value.fresh) {
		return socialwireredis.Fresh, value.endpoint, nil
	}
	return socialwireredis.Stale, value.endpoint, nil
}
func (r *Repository) store(ctx context.Context, did, endpoint string, now time.Time) error {
	fresh, hard := 30*time.Minute, 6*time.Hour
	if endpoint == "" {
		fresh, hard = time.Minute, 5*time.Minute
	}
	if r.cache != nil {
		return socialwireredis.StoreValue(ctx, r.cache, r.namespace.Key("pds-resolution", nil, []string{did}), storedResolution{Endpoint: endpoint}, socialwireredis.CachePolicy{FreshDuration: fresh, HardDuration: hard, MaximumJitterFraction: .1}, now)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, value := range r.entries {
		if !now.Before(value.hard) {
			delete(r.entries, id)
		}
	}
	if len(r.entries) >= 4096 {
		for id := range r.entries {
			delete(r.entries, id)
			break
		}
	}
	r.entries[did] = entry{endpoint, now.Add(fresh), now.Add(hard)}
	return nil
}

// Invalidate removes only this environment's disposable resolution, never repository data.
func (r *Repository) Invalidate(ctx context.Context, did string) error {
	if r.cache != nil {
		return r.cache.Commands.Delete(ctx, []string{r.namespace.Key("pds-resolution", nil, []string{did})})
	}
	r.mu.Lock()
	delete(r.entries, did)
	r.mu.Unlock()
	return nil
}
