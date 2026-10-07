package appviewworkercore

import (
	"testing"
	"time"
)

func TestProactiveBackfillConfigurationPreservesAuthoritativeSuppression(t *testing.T) {
	env := map[string]string{"APP_ENV": "dev", "ENABLE_THIN_APPVIEW": "true", "THIN_APPVIEW_JETSTREAM_MODE": "v2_authoritative"}
	config, err := hostConfiguration(env, "coordinator")
	if err != nil {
		t.Fatal(err)
	}
	if !config.ProactiveBackfillEnabled || config.ProactiveBackfillInterval != 15*time.Minute || config.ProactiveBackfillAuthorLimit != 40 || !config.ProactiveBackfillSuppressed() {
		t.Fatal(config)
	}
	env["THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED"] = "false"
	config, err = hostConfiguration(env, "coordinator")
	if err != nil || config.ProactiveBackfillSuppressed() {
		t.Fatalf("disabled policy: %+v %v", config, err)
	}
	env["THIN_APPVIEW_PROACTIVE_BACKFILL_ENABLED"] = "true"
	env["THIN_APPVIEW_PROACTIVE_BACKFILL_INTERVAL_SECONDS"] = "120"
	env["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_LIMIT"] = "12"
	env["THIN_APPVIEW_PROACTIVE_BACKFILL_AUTHOR_DIDS"] = " did:plc:fixture , ,did:web:fixture.example "
	config, err = hostConfiguration(env, "projection")
	if err != nil || config.ProactiveBackfillSuppressed() || config.ProactiveBackfillInterval != 2*time.Minute || config.ProactiveBackfillAuthorLimit != 12 || len(config.ProactiveBackfillAuthorDIDs) != 2 || config.ProactiveBackfillAuthorDIDs[0] != "did:plc:fixture" {
		t.Fatalf("projection policy: %+v %v", config, err)
	}
	// Suppression cannot accidentally activate a legacy, unfenced runner: the Go
	// host rejects every mode that could permit that runner in the Swift host.
	for _, mode := range []string{"legacy", "v2_shadow"} {
		env["THIN_APPVIEW_JETSTREAM_MODE"] = mode
		if _, err := hostConfiguration(env, "coordinator"); err == nil {
			t.Fatalf("accepted unsupported intake authority %s", mode)
		}
	}
}
