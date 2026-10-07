package runtime

import (
	"encoding/json"
	"errors"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"strings"
	"time"
)

// Observe only canonical disposable projection domains. Neither metric labels nor
// error values contain cache keys, viewer identities, or cached payloads.
func (h RedisTelemetryHook) lookup(cmd redis.Cmder, err error) {
	if h.Buffer == nil || !strings.EqualFold(cmd.Name(), "get") || len(cmd.Args()) < 2 {
		return
	}
	key, ok := cmd.Args()[1].(string)
	if !ok {
		return
	}
	parts := strings.Split(key, ":")
	if len(parts) < 4 || parts[0] != "sw" {
		return
	}
	cacheType := parts[3]
	switch cacheType {
	case "sidebar", "unread", "firstpage":
	default:
		return
	}
	outcome := "miss"
	if err != nil && !errors.Is(err, redis.Nil) {
		outcome = "fallback"
	}
	if value, ok := cmd.(*redis.StringCmd); ok && err == nil {
		raw := value.Val()
		var metadata struct {
			SchemaVersion                       *int `json:"schemaVersion"`
			CachedAt, FreshUntil, HardExpiresAt *float64
			Value                               json.RawMessage
		}
		if len(raw) > 8<<20 || json.Unmarshal([]byte(raw), &metadata) != nil || metadata.SchemaVersion == nil || metadata.CachedAt == nil || metadata.FreshUntil == nil || metadata.HardExpiresAt == nil || metadata.Value == nil {
			outcome = "malformed"
		} else if *metadata.SchemaVersion == 1 && float64(time.Now().UnixMilli()) < *metadata.HardExpiresAt {
			outcome = "stale_hit"
			if float64(time.Now().UnixMilli()) < *metadata.FreshUntil {
				outcome = "fresh_hit"
			}
		}
	}
	if cacheType == "firstpage" {
		cacheType = "first_page"
	}
	h.Buffer.Enqueue(telemetrycore.MetricSample{Name: "socialwire.appview.cache.lookups_total", Value: 1, Dimensions: map[string]string{"service": h.Service, "cache_type": cacheType, "outcome": outcome}, At: time.Now()})
}
