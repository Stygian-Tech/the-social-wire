package gateway

import (
	"context"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"net/http"
	"strings"
	"sync"
	"time"
)

type requestBucket struct {
	tokens float64
	at     time.Time
}
type RequestLimiter struct {
	Redis     *redis.Client
	Namespace socialwireredis.KeyNamespace
	mu        sync.Mutex
	buckets   map[string]requestBucket
}

func (l *RequestLimiter) consume(ctx context.Context, key string, authenticated bool, now time.Time) bool {
	audience, rate, capacity := "anonymous", 1., 30.
	if authenticated {
		audience, rate, capacity = "authenticated", 2., 60.
	}
	if l.Redis != nil {
		script := `local v=redis.call('HMGET',KEYS[1],'tokens','updated_at') local capacity=tonumber(ARGV[3]) local tokens=tonumber(v[1]) or capacity local updated=tonumber(v[2]) or tonumber(ARGV[1]) local elapsed=math.max(0,tonumber(ARGV[1])-updated) tokens=math.min(capacity,tokens+(elapsed*tonumber(ARGV[2]))) local allowed=0 if tokens>=1 then tokens=tokens-1 allowed=1 end redis.call('HSET',KEYS[1],'tokens',tokens,'updated_at',ARGV[1]) redis.call('PEXPIRE',KEYS[1],ARGV[4]) return allowed`
		value, e := l.Redis.Eval(ctx, script, []string{l.Namespace.Key("wire-rate-limit", []string{audience}, []string{key})}, now.UnixMilli(), rate/1000, capacity, 120000).Int()
		if e == nil {
			return value == 1
		}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.buckets == nil {
		l.buckets = map[string]requestBucket{}
	}
	key = audience + ":" + key
	b, exists := l.buckets[key]
	if !exists {
		b = requestBucket{capacity, now}
	}
	elapsed := max(0, now.Sub(b.at).Seconds())
	b.tokens = min(capacity, b.tokens+elapsed*rate)
	b.at = now
	allowed := b.tokens >= 1
	if allowed {
		b.tokens--
	}
	l.buckets[key] = b
	if len(l.buckets) > 20000 {
		for k, b := range l.buckets {
			if now.Sub(b.at) > 120*time.Second {
				delete(l.buckets, k)
			}
		}
	}
	return allowed
}
func (l *RequestLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		key := auth.DID
		if !ok {
			key = "unknown"
			for _, h := range []string{"CF-Connecting-IP", "X-Forwarded-For"} {
				if v := strings.TrimSpace(strings.Split(r.Header.Get(h), ",")[0]); v != "" {
					key = v
					break
				}
			}
		}
		if !l.consume(r.Context(), key, ok, time.Now()) {
			writeError(w, 429, "Too many discovery requests")
			return
		}
		next.ServeHTTP(w, r)
	})
}
