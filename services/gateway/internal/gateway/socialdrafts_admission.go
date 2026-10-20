package gateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

const socialDraftUploadTimeout = 2 * time.Minute
const socialDraftUploadSlots = 8
const socialDraftOwnerUploadSlots = 2

// Limits share a Redis namespace across replicas. Without Redis, the same bounds
// apply per process; a configured Redis outage fails closed instead of multiplying
// allowances across replicas. Neither admission path uses PostgreSQL connections.
type socialDraftAdmission struct {
	redis     *redis.Client
	namespace socialwireredis.KeyNamespace
	mu        sync.Mutex
	owners    map[string]draftOwnerAdmission
	active    int
}

type draftOwnerAdmission struct {
	requests, uploads requestBucket
	active            int
}

// One atomic decision consumes tokens and, for uploads, claims expiring slots.
// Redis TIME avoids clock skew between Gateway replicas. The slot lease exceeds
// the enforced upload deadline, so process crashes recover without renewal loops.
const socialDraftAdmissionScript = `
local clock=redis.call('TIME')
local now=tonumber(clock[1])*1000+tonumber(clock[2])/1000
local upload=ARGV[1]=='1'
local function bucket(key,capacity,rate)
 local v=redis.call('HMGET',key,'tokens','updated_at')
 local tokens=tonumber(v[1]) or capacity
 local updated=tonumber(v[2]) or now
 return math.min(capacity,tokens+math.max(0,now-updated)*rate)
end
local requests=bucket(KEYS[1],120,0.01)
if requests<1 then return 0 end
local uploads=0
if upload then
 uploads=bucket(KEYS[2],32,0.001)
 if uploads<1 then return 0 end
 redis.call('ZREMRANGEBYSCORE',KEYS[3],'-inf',now)
 redis.call('ZREMRANGEBYSCORE',KEYS[4],'-inf',now)
 if redis.call('ZCARD',KEYS[3])>=8 or redis.call('ZCARD',KEYS[4])>=2 then return 0 end
 local expires=now+tonumber(ARGV[3])
 redis.call('ZADD',KEYS[3],expires,ARGV[2])
 redis.call('ZADD',KEYS[4],expires,ARGV[2])
 redis.call('PEXPIRE',KEYS[3],ARGV[3])
 redis.call('PEXPIRE',KEYS[4],ARGV[3])
 redis.call('HSET',KEYS[2],'tokens',uploads-1,'updated_at',now)
 redis.call('PEXPIRE',KEYS[2],120000)
end
redis.call('HSET',KEYS[1],'tokens',requests-1,'updated_at',now)
redis.call('PEXPIRE',KEYS[1],120000)
return 1
`

func (a *socialDraftAdmission) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		if !ok || strings.TrimSpace(auth.DID) == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
			writeError(w, 401, "Authentication required")
			return
		}
		upload := r.URL.Path == "/xrpc/app.thesocialwire.socialDraft.uploadAttachment"
		release, status := a.acquire(r.Context(), auth.DID, upload, time.Now())
		if status != 0 {
			// Do not let HTTP/1 drain a rejected, potentially stalled upload body
			// after admission has returned. HTTP/2 closes the request stream itself.
			if upload {
				w.Header().Set("Connection", "close")
			}
			w.Header().Set("Retry-After", "1")
			if status == 503 {
				writeError(w, status, "Private draft admission unavailable")
			} else {
				writeError(w, status, "Too many private draft requests")
			}
			return
		}
		defer release()
		next.ServeHTTP(w, r)
	})
}

func (a *socialDraftAdmission) acquire(ctx context.Context, owner string, upload bool, now time.Time) (func(), int) {
	if a.redis == nil {
		return a.acquireLocal(owner, upload, now, true)
	}
	// A local cap also protects each process from a Redis reset or expired leases.
	localRelease, status := a.acquireLocal(owner, upload, now, false)
	if status != 0 {
		return nil, status
	}
	var tokenBytes [16]byte
	if _, err := rand.Read(tokenBytes[:]); err != nil {
		localRelease()
		return nil, 503
	}
	token := hex.EncodeToString(tokenBytes[:])
	keys := []string{
		a.namespace.Key("social-draft-admission", []string{"requests"}, []string{owner}),
		a.namespace.Key("social-draft-admission", []string{"uploads"}, []string{owner}),
		a.namespace.Key("social-draft-admission", []string{"active-uploads"}, nil),
		a.namespace.Key("social-draft-admission", []string{"active-owner"}, []string{owner}),
	}
	work, cancel := context.WithTimeout(ctx, 250*time.Millisecond)
	value, err := a.redis.Eval(work, socialDraftAdmissionScript, keys, upload, token, (socialDraftUploadTimeout + 5*time.Second).Milliseconds()).Int()
	cancel()
	if err != nil {
		localRelease()
		return nil, 503
	}
	if value != 1 {
		localRelease()
		return nil, 429
	}
	return func() {
		defer localRelease()
		if upload {
			cleanup, stop := context.WithTimeout(context.WithoutCancel(ctx), 250*time.Millisecond)
			defer stop()
			// A random lease member prevents a stale release from removing another upload.
			pipe := a.redis.Pipeline()
			pipe.ZRem(cleanup, keys[2], token)
			pipe.ZRem(cleanup, keys[3], token)
			_, _ = pipe.Exec(cleanup)
		}
	}, 0
}

func refillDraftBucket(b requestBucket, now time.Time, capacity, rate float64) requestBucket {
	if b.at.IsZero() {
		return requestBucket{tokens: capacity, at: now}
	}
	b.tokens = min(capacity, b.tokens+max(0, now.Sub(b.at).Seconds())*rate)
	b.at = now
	return b
}

func (a *socialDraftAdmission) acquireLocal(owner string, upload bool, now time.Time, rateLimit bool) (func(), int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.owners == nil {
		a.owners = map[string]draftOwnerAdmission{}
	}
	if len(a.owners) >= 20000 {
		for key, state := range a.owners {
			if state.active == 0 && now.Sub(state.requests.at) > 2*time.Minute {
				delete(a.owners, key)
			}
		}
		if _, ok := a.owners[owner]; !ok && len(a.owners) >= 20000 {
			return nil, 429
		}
	}
	state := a.owners[owner]
	state.requests = refillDraftBucket(state.requests, now, 120, 10)
	state.uploads = refillDraftBucket(state.uploads, now, 32, 1)
	if (rateLimit && (state.requests.tokens < 1 || (upload && state.uploads.tokens < 1))) || (upload && (a.active >= socialDraftUploadSlots || state.active >= socialDraftOwnerUploadSlots)) {
		return nil, 429
	}
	if rateLimit {
		state.requests.tokens--
		if upload {
			state.uploads.tokens--
		}
	}
	if upload {
		a.active++
		state.active++
	}
	a.owners[owner] = state
	return func() {
		if !upload {
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		state := a.owners[owner]
		state.active--
		a.active--
		a.owners[owner] = state
	}, 0
}
