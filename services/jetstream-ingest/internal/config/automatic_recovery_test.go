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
