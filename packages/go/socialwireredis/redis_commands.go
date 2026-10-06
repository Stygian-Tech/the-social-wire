package socialwireredis

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

func (r RedisCommands) Get(ctx context.Context, key string) ([]byte, error) {
	data, err := r.Client.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	return data, err
}
func (r RedisCommands) Set(ctx context.Context, key string, data []byte, ttl time.Duration) error {
	return r.Client.Set(ctx, key, data, ttl).Err()
}
func (r RedisCommands) Delete(ctx context.Context, keys []string) error {
	if len(keys) == 0 {
		return nil
	}
	return r.Client.Del(ctx, keys...).Err()
}
