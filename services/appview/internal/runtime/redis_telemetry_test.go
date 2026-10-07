package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRedisHostMetricsPreserveSourceDimensionsAndExcludeKeys(t *testing.T) {
	samples := []telemetrycore.MetricSample{}
	buffer := &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, batch []telemetrycore.MetricSample) error {
		samples = append(samples, batch...)
		return nil
	}}
	hook := RedisTelemetryHook{Buffer: buffer, Service: "appview"}
	key := socialwireredis.NewKeyNamespace("prod", "v1").Key("firstpage", nil, []string{"private-publication", "did:plc:private-viewer"})
	now := time.Now().UnixMilli()
	raw := `{"schemaVersion":1,"cachedAt":` + fmtInt(now) + `,"freshUntil":` + fmtInt(now+60000) + `,"hardExpiresAt":` + fmtInt(now+120000) + `,"value":"private body"}`
	cmd := redis.NewStringCmd(context.Background(), "get", key)
	cmd.SetVal(raw)
	hook.lookup(cmd, nil)
	hook.record("get", time.Now().Add(-time.Millisecond), nil)
	hook.record("private-command", time.Now(), errors.New("private identity error"))
	hook.record("set_nx", time.Now(), context.DeadlineExceeded)
	if _, e := buffer.Flush(context.Background()); e != nil {
		t.Fatal(e)
	}
	if len(samples) != 4 {
		t.Fatal(samples)
	}
	if samples[0].Dimensions["cache_type"] != "first_page" || samples[0].Dimensions["outcome"] != "fresh_hit" || samples[2].Dimensions["operation"] != "other" || samples[3].Dimensions["error_category"] != "timeout" {
		t.Fatal(samples)
	}
	encoded, _ := json.Marshal(samples)
	for _, private := range []string{"private-publication", "private-viewer", "private body", "private identity error", key} {
		if strings.Contains(string(encoded), private) {
			t.Fatal("private metric dimension leaked")
		}
	}
}
func fmtInt(n int64) string { return strconv.FormatInt(n, 10) }
func TestCachePolicyUsesFinitePositiveSourceOverrides(t *testing.T) {
	for _, bad := range []string{"", "NaN", "Inf", "-1", "0", "bad"} {
		if got := positiveDuration(bad, time.Minute); got != time.Minute {
			t.Fatal(bad, got)
		}
	}
	if got := positiveDuration("0.25", time.Minute); got != 250*time.Millisecond {
		t.Fatal(got)
	}
}
