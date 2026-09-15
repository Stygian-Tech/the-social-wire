package config

import (
	"strings"
	"testing"
	"time"
)

func TestReplayCanaryConfigurationPaths(t *testing.T) {
	for _, test := range []struct {
		name, prefix string
		named        bool
	}{
		{"standalone", "JETSTREAM_", false},
		{"controller", "JETSTREAM_WIRE_", false},
		{"named_wire_lane", "JETSTREAM_WIRE_EXTERNAL_", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("APP_ENV", "dev")
			t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
			t.Setenv("JETSTREAM_API_KEY", "test-key")
			t.Setenv("JETSTREAM_APPVIEW_ENABLED", "false")
			t.Setenv("JETSTREAM_WIRE_ENABLED", "false")
			t.Setenv("JETSTREAM_WIRE_LANES", "")
			if test.prefix == "JETSTREAM_" {
				t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
				setRequiredWireAdmission(t)
			} else if test.named {
				t.Setenv("JETSTREAM_WIRE_LANES", "external")
				t.Setenv(test.prefix+"ADMISSION_RATE_PER_SECOND", "1")
			} else {
				t.Setenv("JETSTREAM_WIRE_ENABLED", "true")
				t.Setenv(test.prefix+"ADMISSION_RATE_PER_SECOND", "1")
			}
			// Past timestamps remain a stop instruction across every restart.
			t.Setenv(test.prefix+"REPLAY_CANARY_EXPIRES_AT", "2020-01-02T03:04:05.123Z")
			var cfg Config
			var err error
			if test.prefix == "JETSTREAM_" {
				cfg, err = Load()
			} else {
				var controller ControllerConfig
				controller, err = LoadController()
				if err == nil {
					cfg = controller.Lanes[0].Config
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			want, _ := time.Parse(time.RFC3339Nano, "2020-01-02T03:04:05.123Z")
			if cfg.ReplayCanaryExpiresAt == nil || !cfg.ReplayCanaryExpiresAt.Equal(want) {
				t.Fatalf("expiry = %v", cfg.ReplayCanaryExpiresAt)
			}
		})
	}
}

func TestReplayCanaryConfigurationRejectsInvalidOrNonWire(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
	setRequiredWireAdmission(t)
	for _, raw := range []string{"15m", "2026-09-15", "invalid", "2026-09-15T11:00:00+01:00"} {
		t.Setenv("JETSTREAM_REPLAY_CANARY_EXPIRES_AT", raw)
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "REPLAY_CANARY_EXPIRES_AT") {
			t.Fatalf("invalid expiry %q: %v", raw, err)
		}
	}
	t.Setenv("JETSTREAM_REPLAY_CANARY_EXPIRES_AT", "2026-09-15T11:00:00Z")
	t.Setenv("JETSTREAM_PIPELINE_MODE", DefaultPipelineMode)
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "only for Wire") {
		t.Fatalf("AppView expiry = %v", err)
	}
	t.Setenv("JETSTREAM_REPLAY_CANARY_EXPIRES_AT", "")
	cfg, err := Load()
	if err != nil || cfg.ReplayCanaryExpiresAt != nil {
		t.Fatalf("unset default = %v, %v", cfg.ReplayCanaryExpiresAt, err)
	}
}
