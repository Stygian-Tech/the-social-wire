package appviewworkercore

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestRedisHookCanonicalMetricsAndArgumentRedaction(t *testing.T) {
	for _, test := range []struct {
		err            error
		name, category string
	}{{nil, "socialwire.redis.operation.duration_seconds", ""}, {redis.Nil, "socialwire.redis.operation.duration_seconds", ""}, {context.DeadlineExceeded, "socialwire.redis.errors_total", "timeout"}, {errors.New("secret redis key"), "socialwire.redis.errors_total", "command_failed"}} {
		var samples []MetricSample
		buffer := &TelemetryBuffer{Export: func(_ context.Context, b []MetricSample) error { samples = b; return nil }}
		hook := RedisTelemetryHook{Buffer: buffer, Service: "projection-pool-appview"}
		cmd := redis.NewCmd(context.Background(), "GET", "secret redis key")
		err := hook.ProcessHook(func(context.Context, redis.Cmder) error { return test.err })(context.Background(), cmd)
		if err != test.err {
			t.Fatal("hook changed command result")
		}
		if _, err := buffer.Flush(context.Background()); err != nil {
			t.Fatal(err)
		}
		if len(samples) != 1 || samples[0].Name != test.name || samples[0].Dimensions["operation"] != "get" || samples[0].Dimensions["error_category"] != test.category || samples[0].Dimensions["service"] != "projection-pool-appview" {
			t.Fatal(samples)
		}
	}
	if redisCommandOperation(redis.NewCmd(context.Background(), "set", "private", "body", "px", 1000, "nx")) != "set_nx" || redisCommandOperation(redis.NewCmd(context.Background(), "del", "private")) != "unlink" {
		t.Fatal("canonical Redis operation mapping changed")
	}
	if redisMetricOperation("secret-body") != "other" {
		t.Fatal("arbitrary command leaked")
	}
}
func TestRedisPipelinePreservesMissAndFailureCategories(t *testing.T) {
	var samples []MetricSample
	buffer := &TelemetryBuffer{Export: func(_ context.Context, b []MetricSample) error { samples = b; return nil }}
	hook := RedisTelemetryHook{Buffer: buffer, Service: "coordinator-appview"}
	cmds := []redis.Cmder{redis.NewCmd(context.Background(), "get", "private"), redis.NewCmd(context.Background(), "set", "private", "body")}
	err := hook.ProcessPipelineHook(func(_ context.Context, items []redis.Cmder) error { items[0].SetErr(redis.Nil); return redis.Nil })(context.Background(), cmds)
	if !errors.Is(err, redis.Nil) {
		t.Fatal(err)
	}
	if _, err := buffer.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(samples) != 2 {
		t.Fatal(samples)
	}
	for _, sample := range samples {
		if sample.Name != "socialwire.redis.operation.duration_seconds" || sample.Value < 0 || sample.At.Before(time.Now().Add(-time.Minute)) {
			t.Fatal(sample)
		}
	}
}
