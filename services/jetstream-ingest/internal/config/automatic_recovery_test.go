package config

import "testing"

func TestAutomaticRecoveryIsExplicitAndRestrictedToFencedPublicationCollections(t *testing.T) {
	t.Setenv("APP_ENV", "prod")
	t.Setenv("DATABASE_URL", "postgres://fixture.invalid/test")
	t.Setenv("JETSTREAM_API_KEY", "fixture")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
	t.Setenv("JETSTREAM_COLLECTIONS", "site.standard.document,site.standard.entry,site.standard.publication")
	setRequiredWireAdmission(t)
	cfg, err := Load()
	if err != nil || cfg.AutomaticRecoveryEnabled {
		t.Fatalf("automatic recovery must default off: %+v %v", cfg, err)
	}
	t.Setenv("JETSTREAM_AUTOMATIC_RECOVERY_ENABLED", "true")
	for _, collections := range []string{"site.standard.document", "site.standard.entry", "site.standard.publication", "site.standard.document,site.standard.entry,site.standard.publication"} {
		t.Setenv("JETSTREAM_COLLECTIONS", collections)
		cfg, err := Load()
		if err != nil || !cfg.AutomaticRecoveryEnabled || !cfg.SupportsAutomaticRecovery() {
			t.Fatalf("fenced scope %s: %+v %v", collections, cfg, err)
		}
	}
	for _, collection := range []string{"app.bsky.feed.post", "site.standard.graph.recommend", "app.thesocialwire.wireFeedback"} {
		t.Setenv("JETSTREAM_COLLECTIONS", "site.standard.document,"+collection)
		if _, err := Load(); err == nil {
			t.Fatalf("accepted unsupported automatic recovery collection %s", collection)
		}
	}
	t.Setenv("JETSTREAM_COLLECTIONS", "site.standard.document")
	t.Setenv("JETSTREAM_REPLAY_SNAPSHOT_ONLY", "true")
	t.Setenv("JETSTREAM_BOOTSTRAP_AFTER_SEQ", "100")
	t.Setenv("JETSTREAM_REPLAY_BEFORE_SEQ", "200")
	if _, err := Load(); err == nil {
		t.Fatal("accepted automatic recovery for bounded snapshot")
	}
	t.Setenv("JETSTREAM_REPLAY_SNAPSHOT_ONLY", "false")
	t.Setenv("JETSTREAM_PIPELINE_MODE", DefaultPipelineMode)
	if _, err := Load(); err == nil {
		t.Fatal("accepted automatic recovery for AppView pipeline")
	}
}

func TestAutomaticRecoveryRejectsEmptyScopeAndInvalidFlag(t *testing.T) {
	if (Config{PipelineMode: WirePipelineMode}).SupportsAutomaticRecovery() {
		t.Fatal("empty scope cannot prove fenced ordering")
	}
	t.Setenv("APP_ENV", "prod")
	t.Setenv("DATABASE_URL", "postgres://fixture.invalid/test")
	t.Setenv("JETSTREAM_API_KEY", "fixture")
	t.Setenv("JETSTREAM_AUTOMATIC_RECOVERY_ENABLED", "sometimes")
	if _, err := Load(); err == nil {
		t.Fatal("invalid explicit flag accepted")
	}
}

func TestNamedPublicationRecoveryKeepsExistingLaneIndependent(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://fixture.invalid/test")
	t.Setenv("JETSTREAM_API_KEY", "fixture")
	t.Setenv("JETSTREAM_APPVIEW_ENABLED", "false")
	t.Setenv("JETSTREAM_WIRE_ENABLED", "false")
	t.Setenv("JETSTREAM_WIRE_LANES", "publicationwest,publicationauto")
	for _, name := range []string{"PUBLICATIONWEST", "PUBLICATIONAUTO"} {
		prefix := "JETSTREAM_WIRE_" + name + "_"
		t.Setenv(prefix+"SOURCE_GENERATION", name)
		t.Setenv(prefix+"LEADER_LEASE_NAME", name)
		t.Setenv(prefix+"HOST", "jetstream.us-west.bsky.network")
		t.Setenv(prefix+"COLLECTIONS", "site.standard.document,site.standard.entry,site.standard.publication")
		t.Setenv(prefix+"ADMISSION_RATE_PER_SECOND", "50")
		t.Setenv(prefix+"ADMISSION_BURST_EVENTS", "64")
	}
	const prefix = "JETSTREAM_WIRE_PUBLICATIONAUTO_"
	t.Setenv(prefix+"AUTOMATIC_RECOVERY_ENABLED", "true")
	t.Setenv(prefix+"BOOTSTRAP_AFTER_SEQ", "26669704344")
	t.Setenv(prefix+"REPLAY_INCIDENT_BYTES", "1073741824")
	t.Setenv(prefix+"REPLAY_DAILY_BYTES", "1073741824")
	t.Setenv(prefix+"REPLAY_CANARY_EXPIRES_AT", "2026-10-30T03:16:00Z")
	controller, err := LoadController()
	if err != nil {
		t.Fatal(err)
	}
	if len(controller.Lanes) != 2 {
		t.Fatalf("unexpected lanes: %#v", controller.Lanes)
	}
	old, automatic := controller.Lanes[0].Config, controller.Lanes[1].Config
	if old.AutomaticRecoveryEnabled || !automatic.AutomaticRecoveryEnabled || old.SourceGeneration == automatic.SourceGeneration || old.FilterFingerprint != automatic.FilterFingerprint {
		t.Fatalf("automatic opt-in changed existing lane identity or mode: old=%+v automatic=%+v", old, automatic)
	}
	if automatic.BootstrapAfterSeq == nil || *automatic.BootstrapAfterSeq != 26669704344 || automatic.ReplayIncidentBytes != 1<<30 || automatic.ReplayDailyBytes != 1<<30 || automatic.ReplayCanaryExpiresAt == nil || automatic.ReplayCanaryExpiresAt.UTC().Format("2006-01-02T15:04:05Z") != "2026-10-30T03:16:00Z" {
		t.Fatalf("named lane lost retained archive controls: %+v", automatic)
	}
}
