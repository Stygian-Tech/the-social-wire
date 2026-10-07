package socialwireredis

// Adapts go-redis commands to the repository cache interface. Missing keys become a nil-
// value miss, empty deletes are no-ops, and callers retain ownership of pools, TLS,
// retry/deadline configuration, and shutdown.

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisCommands uses go-redis directly for pooling, transport, and commands.
// The caller owns the client, including its TLS/deadline options and Close.
type RedisCommands struct{ Client redis.Cmdable }

var _ Commands = RedisCommands{}

// Get maps redis.Nil to a cache miss without counting absence as a backend failure.
func (commands RedisCommands) Get(ctx context.Context, key string) ([]byte, error) {
	data, err := commands.Client.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	return data, err
}

// Set writes bytes with the caller-supplied TTL through go-redis.
func (commands RedisCommands) Set(ctx context.Context, key string, data []byte, ttl time.Duration) error {
	return commands.Client.Set(ctx, key, data, ttl).Err()
}

// Delete deletes the supplied keys and treats an empty list as a successful no-op.
func (commands RedisCommands) Delete(ctx context.Context, keys []string) error {
	if len(keys) == 0 {
		return nil
	}
	return commands.Client.Del(ctx, keys...).Err()
}
