package repocache

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"
)

const releaseScript = `if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end`

func (r *Repository) acquire(ctx context.Context, did string, now time.Time) (string, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", err
	}
	owner := hex.EncodeToString(token[:])
	key := r.namespace.Key("lock", []string{"pds-resolution"}, []string{did})
	if r.redis != nil {
		held, err := r.redis.SetNX(ctx, key, owner, 15*time.Second).Result()
		if err != nil || !held {
			return "", err
		}
		return owner, nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, lease := range r.leases {
		if !now.Before(lease.expires) {
			delete(r.leases, id)
		}
	}
	if current, ok := r.leases[did]; ok && now.Before(current.expires) {
		return "", nil
	}
	if len(r.leases) >= 4096 {
		return "", nil
	}
	r.leases[did] = localLease{owner, now.Add(15 * time.Second)}
	return owner, nil
}
func (r *Repository) release(did, owner string) {
	if r.redis != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = r.redis.Eval(ctx, releaseScript, []string{r.namespace.Key("lock", []string{"pds-resolution"}, []string{did})}, owner).Err()
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.leases[did].owner == owner {
		delete(r.leases, did)
	}
}
