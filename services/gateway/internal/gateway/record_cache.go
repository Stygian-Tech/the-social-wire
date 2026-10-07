package gateway

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"sync"
	"time"
)

type RecordSnapshot struct {
	CID      *string `json:"cid"`
	JSONBody string  `json:"jsonBody"`
	CachedAt float64 `json:"cachedAt"`
}
type RecordCache struct {
	DB        *sql.DB
	Redis     *redis.Client
	Backend   string
	Namespace socialwireredis.KeyNamespace
	mu        sync.Mutex
	client    *socialwireredis.CacheClient
}

func (c *RecordCache) redisCache() *socialwireredis.CacheClient {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client == nil {
		c.client = socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: c.Redis})
	}
	return c.client
}
func (c *RecordCache) key(did, scope string) string {
	return c.Namespace.Key("pds", nil, []string{did, scope})
}
func (c *RecordCache) Get(ctx context.Context, did, scope string) (*RecordSnapshot, error) {
	if c.Backend == "redis" {
		if c.Redis == nil {
			return nil, nil
		}
		v, e := socialwireredis.LookupValue[RecordSnapshot](ctx, c.redisCache(), c.key(did, scope), time.Now())
		if e != nil || v.Envelope == nil {
			return nil, nil
		}
		return &v.Envelope.Value, nil
	}
	if c.DB == nil {
		return nil, nil
	}
	var v RecordSnapshot
	var at time.Time
	err := c.DB.QueryRowContext(ctx, `SELECT cid,json_body,cached_at FROM pds_repo_record_cache WHERE owner_did=$1 AND scope_key=$2 AND expires_at>clock_timestamp()`, did, scope).Scan(&v.CID, &v.JSONBody, &at)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	v.CachedAt = float64(at.UnixMilli())
	return &v, nil
}
func (c *RecordCache) Put(ctx context.Context, did, scope string, v RecordSnapshot) error {
	fresh, hard := 2*time.Minute, 20*time.Minute
	if scope == "app.thesocialwire.preferences:self" {
		fresh, hard = 5*time.Minute, 30*time.Minute
	}
	at := time.UnixMilli(int64(v.CachedAt))
	if c.Backend == "redis" {
		if c.Redis == nil {
			return nil
		}
		_ = socialwireredis.StoreValue(ctx, c.redisCache(), c.key(did, scope), v, socialwireredis.CachePolicy{FreshDuration: fresh, HardDuration: hard}, at)
		return nil
	}
	if c.DB == nil {
		return nil
	}
	_, e := c.DB.ExecContext(ctx, `INSERT INTO pds_repo_record_cache(owner_did,scope_key,cid,json_body,cached_at,expires_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(owner_did,scope_key) DO UPDATE SET cid=EXCLUDED.cid,json_body=EXCLUDED.json_body,cached_at=EXCLUDED.cached_at,expires_at=EXCLUDED.expires_at`, did, scope, v.CID, v.JSONBody, at, at.Add(hard))
	return e
}
func (c *RecordCache) Acquire(ctx context.Context, did, scope string) (*thinappviewcore.RefreshLease, error) {
	transport := c.Redis
	if c.Backend != "redis" {
		transport = nil
	}
	pool := thinappviewcore.ProjectionCache{Redis: transport, Namespace: c.Namespace}
	lease, e := pool.AcquireRefreshLease(ctx, "pds", did+":"+scope, 15*time.Second)
	if e != nil {
		return &thinappviewcore.RefreshLease{TTL: 15 * time.Second}, nil
	}
	return lease, nil
}
func (c *RecordCache) Renew(ctx context.Context, l thinappviewcore.RefreshLease) bool {
	ok, _ := (thinappviewcore.ProjectionCache{Redis: c.Redis}).RenewRefreshLease(ctx, l)
	return ok
}
func (c *RecordCache) Release(ctx context.Context, l thinappviewcore.RefreshLease) {
	_ = (thinappviewcore.ProjectionCache{Redis: c.Redis}).ReleaseRefreshLease(ctx, l)
}
func snapshotRecord(v *RecordSnapshot) (*json.RawMessage, error) {
	var root struct {
		Value json.RawMessage `json:"value"`
	}
	if json.Unmarshal([]byte(v.JSONBody), &root) != nil {
		return nil, errors.New("invalid record cache")
	}
	if len(root.Value) == 0 || string(root.Value) == "null" {
		return nil, nil
	}
	return &root.Value, nil
}
