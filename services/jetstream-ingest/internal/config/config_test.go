package config

import (
	"slices"
	"testing"
)

func TestFilterFingerprintIgnoresCollectionOrderingAndDuplicates(t *testing.T) {
	first := FilterFingerprint(DefaultStreamNSID, []string{"site.standard.entry", "site.standard.document"})
	second := FilterFingerprint(DefaultStreamNSID, []string{"site.standard.document", "site.standard.entry", "site.standard.entry"})
	if first != second {
		t.Fatalf("fingerprints differ: %q != %q", first, second)
	}
}

func TestLoadDefaultsToUSWestAndAllEventKinds(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Host != DefaultHost {
		t.Fatalf("host = %q", cfg.Host)
	}
	if cfg.SourceGeneration != DefaultSourceGeneration {
		t.Fatalf("source generation = %q", cfg.SourceGeneration)
	}
	if !slices.Contains(cfg.Collections, "site.standard.document") || !slices.Contains(cfg.Collections, "app.skyreader.feed.subscription") {
		t.Fatalf("collections = %#v", cfg.Collections)
	}
}

func TestHostedConfigRequiresArchiveKey(t *testing.T) {
	cfg := Config{
		Environment: "dev", DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
		SourceGeneration: DefaultSourceGeneration, Collections: []string{"site.standard.entry"},
		Port: 8080, BatchSize: 64, DownloadConcurrency: 1, SegmentStripes: 1,
		MaxDownloadAttempts: 1, LeaderLeaseTTL: 30, TrackedDIDRefresh: 10,
		ReplayIncidentBytes: 1, ReplayDailyBytes: 1, ReplayBudgetPause: 1,
		BackoffMin: 1, BackoffMax: 1,
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected missing API key validation error")
	}
}
