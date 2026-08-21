package config

import (
	"slices"
	"strings"
	"testing"
	"time"
)

func TestFilterFingerprintIgnoresCollectionOrderingAndDuplicates(t *testing.T) {
	first := FilterFingerprint(DefaultStreamNSID, []string{"site.standard.entry", "site.standard.document"}, DefaultScopePolicy)
	second := FilterFingerprint(DefaultStreamNSID, []string{"site.standard.document", "site.standard.entry", "site.standard.entry"}, DefaultScopePolicy)
	if first != second {
		t.Fatalf("fingerprints differ: %q != %q", first, second)
	}
}

func TestFilterFingerprintChangesWithScopePolicy(t *testing.T) {
	collections := []string{"site.standard.document"}
	first := FilterFingerprint(DefaultStreamNSID, collections, "publication-author-viewer-v1")
	second := FilterFingerprint(DefaultStreamNSID, collections, "publication-author-viewer-v2")
	if first == second {
		t.Fatalf("scope policy did not change fingerprint: %q", first)
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
	if cfg.ScopePolicy != DefaultScopePolicy {
		t.Fatalf("scope policy = %q", cfg.ScopePolicy)
	}
	if !slices.Contains(cfg.Collections, "site.standard.document") || !slices.Contains(cfg.Collections, "app.skyreader.feed.subscription") {
		t.Fatalf("collections = %#v", cfg.Collections)
	}
	if slices.Contains(cfg.Collections, "app.thesocialwire.entryReadState") {
		t.Fatalf("read-state records should not be consumed by V2: %#v", cfg.Collections)
	}
}

func TestHostedConfigRequiresArchiveKey(t *testing.T) {
	cfg := Config{
		PipelineMode: DefaultPipelineMode,
		Environment: "dev", DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
		SourceGeneration: DefaultSourceGeneration, Collections: []string{"site.standard.entry"},
		ScopePolicy: DefaultScopePolicy,
		Port:        8080, BatchSize: 64, DownloadConcurrency: 1, SegmentStripes: 1,
		MaxDownloadAttempts: 1, LeaderLeaseTTL: 30, TrackedDIDRefresh: 10,
		ReplayIncidentBytes: 1, ReplayDailyBytes: 1, ReplayBudgetPause: 1,
		BackoffMin: 1, BackoffMax: 1,
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("expected missing API key validation error")
	}
}

func TestConfigRejectsCollectionsWithoutAScopeRole(t *testing.T) {
	cfg := Config{
		PipelineMode: DefaultPipelineMode,
		Environment: "dev", DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
		SourceGeneration: DefaultSourceGeneration, Collections: []string{"example.unsupported.record"},
		ScopePolicy: DefaultScopePolicy, APIKey: "test-key",
		Port: 8080, BatchSize: 64, DownloadConcurrency: 1, SegmentStripes: 1,
		MaxDownloadAttempts: 1, LeaderLeaseTTL: 30, TrackedDIDRefresh: 10,
		ReplayIncidentBytes: 1, ReplayDailyBytes: 1, ReplayBudgetPause: time.Minute,
		BackoffMin: 1, BackoffMax: 1,
	}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "unsupported JETSTREAM_COLLECTIONS") {
		t.Fatalf("validation error = %v", err)
	}
}

func TestLoadWirePipelineUsesIndependentIdentityAndGlobalCollections(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SourceGeneration != WireSourceGeneration || cfg.ScopePolicy != WireScopePolicy {
		t.Fatalf("wire identity = generation %q policy %q", cfg.SourceGeneration, cfg.ScopePolicy)
	}
	if cfg.LeaderLeaseName != "wire-global-v1-ingest" {
		t.Fatalf("wire lease name = %q", cfg.LeaderLeaseName)
	}
	for _, required := range []string{
		"site.standard.graph.recommend", "app.bsky.feed.post", "app.bsky.feed.like",
		"app.bsky.feed.repost", "app.bsky.graph.follow",
	} {
		if !slices.Contains(cfg.Collections, required) {
			t.Fatalf("wire collections missing %q: %#v", required, cfg.Collections)
		}
	}
	if cfg.FilterFingerprint == FilterFingerprint(DefaultStreamNSID, DefaultCollections, DefaultScopePolicy) {
		t.Fatal("wire pipeline reused the publication-author-viewer fingerprint")
	}
}
