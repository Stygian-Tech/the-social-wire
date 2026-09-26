package config

import (
	"testing"
	"time"
)

func TestDatabasePoolConfigurationPerLane(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/db")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DatabasePoolMaxOpen != 8 || cfg.DatabasePoolMaxIdle != 1 || cfg.DatabasePoolIdleTimeout != time.Minute || cfg.WireCompactIngestEnabled {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	t.Setenv("JETSTREAM_APPVIEW_ENABLED", "true")
	t.Setenv("JETSTREAM_WIRE_ENABLED", "true")
	t.Setenv("JETSTREAM_WIRE_ADMISSION_RATE_PER_SECOND", "1000")
	t.Setenv("JETSTREAM_WIRE_INBOX_MAX_ROWS", "5000000")
	t.Setenv("JETSTREAM_WIRE_DATABASE_MAX_BYTES", "85899345920")
	t.Setenv("JETSTREAM_APPVIEW_DATABASE_POOL_MAX_OPEN", "4")
	t.Setenv("JETSTREAM_APPVIEW_DATABASE_POOL_MAX_IDLE", "0")
	t.Setenv("JETSTREAM_APPVIEW_DATABASE_POOL_IDLE_TIMEOUT", "30s")
	t.Setenv("JETSTREAM_WIRE_COMPACT_INGEST_ENABLED", "true")
	controller, err := LoadController()
	if err != nil {
		t.Fatal(err)
	}
	appview, wire := controller.Lanes[0].Config, controller.Lanes[1].Config
	if appview.DatabasePoolMaxOpen != 4 || appview.DatabasePoolMaxIdle != 0 || appview.DatabasePoolIdleTimeout != 30*time.Second || appview.WireCompactIngestEnabled {
		t.Fatalf("appview pool = %+v", appview)
	}
	if wire.DatabasePoolMaxOpen != 8 || wire.DatabasePoolMaxIdle != 1 || !wire.WireCompactIngestEnabled {
		t.Fatalf("wire pool = %+v", wire)
	}
}

func TestDatabasePoolRejectsInvalidConfiguration(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/db")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	for key, value := range map[string]string{"DATABASE_POOL_MAX_OPEN": "1", "DATABASE_POOL_MAX_IDLE": "9", "DATABASE_POOL_IDLE_TIMEOUT": "0s", "DATABASE_POOL_MAX_OPEN_INVALID": "nonsense"} {
		t.Run(key, func(t *testing.T) {
			if key == "DATABASE_POOL_MAX_OPEN_INVALID" {
				key = "DATABASE_POOL_MAX_OPEN"
			}
			t.Setenv("JETSTREAM_"+key, value)
			if _, err := Load(); err == nil {
				t.Fatal("invalid pool option accepted")
			}
		})
	}
	t.Setenv("JETSTREAM_WIRE_COMPACT_INGEST_ENABLED", "invalid")
	if _, err := Load(); err == nil {
		t.Fatal("invalid rollout flag accepted")
	}
}
