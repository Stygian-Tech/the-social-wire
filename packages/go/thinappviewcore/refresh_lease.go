package thinappviewcore

import (
	"context"
	"time"
)

type RefreshLease struct {
	Key, Owner string
	TTL        time.Duration
}

func (c ProjectionCache) AcquireRefreshLease(ctx context.Context, domain, resource string, ttl time.Duration) (*RefreshLease, error) {
	owner, err := inboxLeaseToken()
	if err != nil {
		return nil, err
	}
	lease := &RefreshLease{Owner: owner, TTL: ttl}
	if c.Redis == nil {
		return lease, nil
	}
	lease.Key = c.Namespace.Key("lock", []string{domain}, []string{resource})
	acquired, err := c.Redis.SetNX(ctx, lease.Key, owner, ttl).Result()
	if c.LockTelemetry != nil && err == nil {
		outcome := "contended"
		if acquired {
			outcome = "acquired"
		}
		c.LockTelemetry(domain, outcome)
	}
	if err != nil {
		return nil, err
	}
	if !acquired {
		return nil, nil
	}
	return lease, nil
}
func (c ProjectionCache) RenewRefreshLease(ctx context.Context, lease RefreshLease) (bool, error) {
	if lease.Key == "" {
		return true, nil
	}
	changed, err := c.Redis.Eval(ctx, `if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('PEXPIRE',KEYS[1],ARGV[2]) else return 0 end`, []string{lease.Key}, lease.Owner, lease.TTL.Milliseconds()).Int()
	return changed == 1, err
}
func (c ProjectionCache) ReleaseRefreshLease(ctx context.Context, lease RefreshLease) error {
	if lease.Key == "" {
		return nil
	}
	return c.Redis.Eval(ctx, `if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end`, []string{lease.Key}, lease.Owner).Err()
}
