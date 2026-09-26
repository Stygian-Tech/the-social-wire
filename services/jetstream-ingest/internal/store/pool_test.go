package store

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

func TestComponentNameRetainsLaneAndBoundsLength(t *testing.T) {
	for _, lane := range []string{"appview", "wire", "wire-live"} {
		name := postgresComponentApplicationName(strings.Repeat("Service ", 20), lane)
		if len(name) > 63 || !strings.HasPrefix(name, lane+".") {
			t.Fatalf("application name = %q", name)
		}
	}
}

func TestPoolTelemetryUsesIntervalWaits(t *testing.T) {
	values := poolLogValues(sql.DBStats{MaxOpenConnections: 8, OpenConnections: 8, InUse: 6, Idle: 2, WaitCount: 15, WaitDuration: 1500 * time.Millisecond}, sql.DBStats{WaitCount: 10, WaitDuration: time.Second})
	got := map[string]any{}
	for i := 0; i < len(values); i += 2 {
		got[values[i].(string)] = values[i+1]
	}
	if got["db_pool_utilization"] != 0.75 || got["db_pool_wait_count"] != int64(5) || got["db_pool_wait_ms"] != int64(500) {
		t.Fatalf("pool sample = %v", got)
	}
}

func TestPoolOpenConfigValidation(t *testing.T) {
	for _, options := range []PoolOptions{{MaxOpen: 1, MaxIdle: 1, IdleTimeout: time.Minute}, {MaxOpen: 8, MaxIdle: 9, IdleTimeout: time.Minute}, {MaxOpen: 8, MaxIdle: 1}} {
		if _, err := OpenWithPool(context.Background(), "postgres://unused/db", testSource(), options, "appview"); err == nil {
			t.Fatalf("invalid pool accepted: %+v", options)
		}
	}
}
