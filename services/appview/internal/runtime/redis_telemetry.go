package runtime

import (
	"context"
	"errors"
	"math"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
)

// RedisTelemetryHook records bounded command categories without Redis keys or arguments.
// Service is the integrated lane's canonical Swift service name.
type RedisTelemetryHook struct {
	Buffer  *telemetrycore.TelemetryBuffer
	Service string
}

func (h RedisTelemetryHook) DialHook(next redis.DialHook) redis.DialHook { return next }
func (h RedisTelemetryHook) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		started := time.Now()
		err := next(ctx, cmd)
		h.record(redisCommandOperation(cmd), started, err)
		h.lookup(cmd, err)
		return err
	}
}
func (h RedisTelemetryHook) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return func(ctx context.Context, cmds []redis.Cmder) error {
		started := time.Now()
		err := next(ctx, cmds)
		for _, cmd := range cmds {
			commandErr := cmd.Err()
			if commandErr == nil && err != nil && !errors.Is(err, redis.Nil) {
				commandErr = err
			}
			h.record(redisCommandOperation(cmd), started, commandErr)
			h.lookup(cmd, commandErr)
		}
		return err
	}
}
func (h RedisTelemetryHook) record(command string, started time.Time, err error) {
	if h.Buffer == nil {
		return
	}
	operation := redisMetricOperation(command)
	dimensions := map[string]string{"service": h.Service, "operation": operation}
	at := time.Now()
	if err == nil || errors.Is(err, redis.Nil) {
		h.Buffer.Enqueue(telemetrycore.MetricSample{Name: "socialwire.redis.operation.duration_seconds", Value: at.Sub(started).Seconds(), Dimensions: dimensions, At: at})
		return
	}
	category := "command_failed"
	var timeout net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &timeout) && timeout.Timeout()) {
		category = "timeout"
	}
	dimensions["error_category"] = category
	h.Buffer.Enqueue(telemetrycore.MetricSample{Name: "socialwire.redis.errors_total", Value: 1, Dimensions: dimensions, At: at})
}
func redisMetricOperation(command string) string {
	switch strings.ToLower(command) {
	case "get", "set", "set_nx", "unlink", "del", "scan", "ping", "eval", "evalsha", "ttl", "pttl", "expire", "pexpire", "mget", "mset", "exists":
		return strings.ToLower(command)
	default:
		return "other"
	}
}

func redisCommandOperation(cmd redis.Cmder) string {
	if strings.EqualFold(cmd.Name(), "set") {
		arguments := cmd.Args()
		for _, argument := range arguments[min(3, len(arguments)):] {
			if option, ok := argument.(string); ok && strings.EqualFold(option, "nx") {
				return "set_nx"
			}
		}
	}
	if strings.EqualFold(cmd.Name(), "del") {
		return "unlink"
	}
	return cmd.Name()
}

func (h *Host) sampleRedis(ctx context.Context) {
	for {
		work, cancel := context.WithTimeout(ctx, 5*time.Second)
		stats, e1 := h.Redis.Info(work, "stats").Result()
		memory, e2 := h.Redis.Info(work, "memory").Result()
		cancel()
		if e1 == nil && e2 == nil && h.Telemetry != nil {
			values := map[string]float64{}
			for _, line := range strings.Split(stats+"\n"+memory, "\n") {
				key, raw, ok := strings.Cut(strings.TrimSpace(line), ":")
				if !ok {
					continue
				}
				value, err := strconv.ParseFloat(raw, 64)
				if err == nil && !math.IsNaN(value) && !math.IsInf(value, 0) && value >= 0 {
					values[key] = value
				}
			}
			for metric, key := range map[string]string{"expired_keys": "expired_keys", "evicted_keys": "evicted_keys", "memory_used_bytes": "used_memory"} {
				if value, ok := values[key]; ok {
					h.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.redis." + metric, Value: value, Dimensions: map[string]string{"service": "appview"}, At: time.Now()})
				}
			}
		}
		timer := time.NewTimer(time.Minute)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
