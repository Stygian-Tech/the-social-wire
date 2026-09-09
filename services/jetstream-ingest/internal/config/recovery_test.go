package config

import "testing"

func TestWireRecoverySharesSourceIdentityWithoutProviderKey(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
	t.Setenv("JETSTREAM_API_KEY", "")
	setRequiredWireAdmission(t)
	lane, err := LoadWireRecovery("wire")
	if err != nil {
		t.Fatal(err)
	}
	if lane.Config.APIKey != "" {
		t.Fatal("recovery unexpectedly requires a provider key")
	}
	if _, err := LoadController(); err == nil {
		t.Fatal("normal ingestion accepted a missing provider key")
	}
	t.Setenv("JETSTREAM_API_KEY", "local-test-key")
	normal, err := LoadController()
	if err != nil {
		t.Fatal(err)
	}
	want := normal.Lanes[0].Config
	if lane.Config.FilterFingerprint != want.FilterFingerprint || lane.Config.SourceGeneration != want.SourceGeneration || lane.Config.Host != want.Host || lane.Config.LeaderLeaseName != want.LeaderLeaseName {
		t.Fatal("recovery changed immutable source identity or lease ownership")
	}
}

func TestWireRecoveryRejectsDisabledAppViewAndInvalidScope(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "")
	t.Setenv("JETSTREAM_APPVIEW_ENABLED", "true")
	t.Setenv("JETSTREAM_WIRE_ENABLED", "false")
	for _, name := range []string{"appview", "wire", "unknown"} {
		if _, err := LoadWireRecovery(name); err == nil {
			t.Fatalf("accepted invalid recovery lane %s", name)
		}
	}
	t.Setenv("JETSTREAM_APPVIEW_ENABLED", "false")
	t.Setenv("JETSTREAM_WIRE_ENABLED", "true")
	t.Setenv("JETSTREAM_WIRE_COLLECTIONS", "unsupported.scope.record")
	t.Setenv("JETSTREAM_WIRE_ADMISSION_RATE_PER_SECOND", "1.5")
	t.Setenv("JETSTREAM_WIRE_ADMISSION_BURST_EVENTS", "1")
	if _, err := LoadWireRecovery("wire"); err == nil {
		t.Fatal("accepted invalid Wire scope")
	}
}
