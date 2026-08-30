package config

import (
	"math"
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
	if cfg.SegmentStripes != DefaultSegmentStripes {
		t.Fatalf("segment stripes = %d, want %d", cfg.SegmentStripes, DefaultSegmentStripes)
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
	if cfg.ReplayBeforeSeq != nil || cfg.ReplaySnapshotOnly {
		t.Fatalf("default replay unexpectedly bounded: before=%v snapshot=%t", cfg.ReplayBeforeSeq, cfg.ReplaySnapshotOnly)
	}
}

func TestLoadBoundedWireSnapshotUsesDistinctGenerationWithoutChangingFingerprint(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
	setRequiredWireAdmission(t)

	base, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("JETSTREAM_SOURCE_GENERATION", "wire-global-v1-dev-24h-snapshot-v1")
	t.Setenv("JETSTREAM_BOOTSTRAP_AFTER_SEQ", "100")
	t.Setenv("JETSTREAM_REPLAY_BEFORE_SEQ", "200")
	t.Setenv("JETSTREAM_REPLAY_SNAPSHOT_ONLY", "true")
	bounded, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if bounded.ReplayBeforeSeq == nil || *bounded.ReplayBeforeSeq != 200 || !bounded.ReplaySnapshotOnly {
		t.Fatalf("bounded replay = before %v snapshot %t", bounded.ReplayBeforeSeq, bounded.ReplaySnapshotOnly)
	}
	if bounded.SourceGeneration == base.SourceGeneration {
		t.Fatalf("bounded generation reused live identity %q", bounded.SourceGeneration)
	}
	if bounded.FilterFingerprint != base.FilterFingerprint || bounded.ScopePolicy != base.ScopePolicy {
		t.Fatalf(
			"replay bounds changed source filter identity: fingerprint %q/%q policy %q/%q",
			bounded.FilterFingerprint, base.FilterFingerprint, bounded.ScopePolicy, base.ScopePolicy,
		)
	}
	if bounded.LeaderLeaseName != base.LeaderLeaseName {
		t.Fatalf("replay bounds changed default lease %q/%q", bounded.LeaderLeaseName, base.LeaderLeaseName)
	}
}

func TestBoundedSnapshotConfigurationFailsClosed(t *testing.T) {
	base := Config{
		PipelineMode: WirePipelineMode, Environment: "dev",
		DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
		SourceGeneration: "wire-global-v1-dev-snapshot-v1", Collections: WireCollections,
		ScopePolicy: WireScopePolicy, APIKey: "test-key",
		Port: 8080, BatchSize: 64, DownloadConcurrency: 1, SegmentStripes: 1,
		MaxDownloadAttempts: 1, LeaderLeaseTTL: 30, TrackedDIDRefresh: 10,
		ReplayIncidentBytes: 1, ReplayDailyBytes: 1, ReplayBudgetPause: time.Minute,
		BackoffMin: 1, BackoffMax: 1,
		WireInboxMaxRows: 1_000, WireDatabaseMaxBytes: 2 << 30,
		WireAdmissionPause: time.Second,
		WireAdmissionRate:  1.5, WireAdmissionBurst: 1,
	}
	after, before := uint64(100), uint64(200)
	zero, tooLarge := uint64(0), uint64(math.MaxInt64)+1

	tests := []struct {
		name   string
		mutate func(*Config)
		want   string
	}{
		{
			name:   "before without snapshot flag",
			mutate: func(cfg *Config) { cfg.ReplayBeforeSeq = &before },
			want:   "required together",
		},
		{
			name:   "snapshot flag without before",
			mutate: func(cfg *Config) { cfg.ReplaySnapshotOnly = true },
			want:   "required together",
		},
		{
			name: "inverted range",
			mutate: func(cfg *Config) {
				cfg.BootstrapAfterSeq = &before
				cfg.ReplayBeforeSeq = &after
				cfg.ReplaySnapshotOnly = true
			},
			want: "must be greater",
		},
		{
			name: "missing exclusive lower bound",
			mutate: func(cfg *Config) {
				cfg.ReplayBeforeSeq = &before
				cfg.ReplaySnapshotOnly = true
			},
			want: "requires JETSTREAM_BOOTSTRAP_AFTER_SEQ",
		},
		{
			name: "zero upper bound",
			mutate: func(cfg *Config) {
				cfg.BootstrapAfterSeq = &zero
				cfg.ReplayBeforeSeq = &zero
				cfg.ReplaySnapshotOnly = true
			},
			want: "must be positive",
		},
		{
			name: "upper bound outside PostgreSQL cursor range",
			mutate: func(cfg *Config) {
				cfg.BootstrapAfterSeq = &after
				cfg.ReplayBeforeSeq = &tooLarge
				cfg.ReplaySnapshotOnly = true
			},
			want: "signed 64-bit cursor range",
		},
		{
			name: "lower bound outside PostgreSQL cursor range",
			mutate: func(cfg *Config) {
				cfg.BootstrapAfterSeq = &tooLarge
				cfg.ReplayBeforeSeq = &tooLarge
				cfg.ReplaySnapshotOnly = true
			},
			want: "JETSTREAM_BOOTSTRAP_AFTER_SEQ exceeds",
		},
		{
			name: "publication lane cannot be bounded",
			mutate: func(cfg *Config) {
				cfg.PipelineMode = DefaultPipelineMode
				cfg.ScopePolicy = DefaultScopePolicy
				cfg.Collections = DefaultCollections
				cfg.BootstrapAfterSeq = &after
				cfg.ReplayBeforeSeq = &before
				cfg.ReplaySnapshotOnly = true
			},
			want: "only by the Wire pipeline",
		},
		{
			name: "default source generation",
			mutate: func(cfg *Config) {
				cfg.SourceGeneration = WireSourceGeneration
				cfg.BootstrapAfterSeq = &after
				cfg.ReplayBeforeSeq = &before
				cfg.ReplaySnapshotOnly = true
			},
			want: "distinct JETSTREAM_SOURCE_GENERATION",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := base
			test.mutate(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validation error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestLoadRejectsInvalidSnapshotBoolean(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_REPLAY_SNAPSHOT_ONLY", "sometimes")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "JETSTREAM_REPLAY_SNAPSHOT_ONLY") {
		t.Fatalf("load error = %v", err)
	}
}

func TestHostedConfigRequiresArchiveKey(t *testing.T) {
	cfg := Config{
		PipelineMode: DefaultPipelineMode,
		Environment:  "dev", DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
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
		Environment:  "dev", DatabaseURL: "postgres://example.invalid/db", Host: DefaultHost,
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
	setRequiredWireAdmission(t)

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SourceGeneration != WireSourceGeneration || cfg.ScopePolicy != WireScopePolicy {
		t.Fatalf("wire identity = generation %q policy %q", cfg.SourceGeneration, cfg.ScopePolicy)
	}
	if cfg.LeaderLeaseName != "wire-global-v4-ingest" {
		t.Fatalf("wire lease name = %q", cfg.LeaderLeaseName)
	}
	if cfg.SegmentStripes != WireSegmentStripes {
		t.Fatalf("wire segment stripes = %d, want %d", cfg.SegmentStripes, WireSegmentStripes)
	}
	for _, required := range []string{
		"site.standard.graph.recommend", "app.thesocialwire.wireFeedback",
		"app.bsky.feed.post", "app.bsky.feed.like",
		"app.bsky.feed.repost", "app.bsky.graph.follow",
		"at.margin.note", "at.margin.reply", "at.margin.like",
		"at.margin.collectionItem", "at.margin.readingRoom",
		"network.cosmik.card", "network.cosmik.connection",
		"network.cosmik.collectionLink", "network.cosmik.collectionLinkRemoval",
	} {
		if !slices.Contains(cfg.Collections, required) {
			t.Fatalf("wire collections missing %q: %#v", required, cfg.Collections)
		}
	}
	for _, legacy := range []string{"at.margin.annotation", "at.margin.highlight", "at.margin.bookmark"} {
		if slices.Contains(cfg.Collections, legacy) {
			t.Fatalf("legacy Margin collection %q must not be consumed", legacy)
		}
	}
	if cfg.FilterFingerprint == FilterFingerprint(DefaultStreamNSID, DefaultCollections, DefaultScopePolicy) {
		t.Fatal("wire pipeline reused the publication-author-viewer fingerprint")
	}
}

func TestLoadWirePipelineAllowsExplicitSegmentStripeOverride(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)
	setRequiredWireAdmission(t)
	t.Setenv("JETSTREAM_SEGMENT_STRIPES", "2")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SegmentStripes != 2 {
		t.Fatalf("wire segment stripes = %d, want explicit override 2", cfg.SegmentStripes)
	}
}

func TestWireAdmissionRateFailsClosed(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("DATABASE_URL", "postgres://example.invalid/socialwire")
	t.Setenv("JETSTREAM_API_KEY", "test-key")
	t.Setenv("JETSTREAM_PIPELINE_MODE", WirePipelineMode)

	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "WIRE_ADMISSION_RATE_PER_SECOND") {
		t.Fatalf("missing rate error = %v", err)
	}
	t.Setenv("WIRE_ADMISSION_RATE_PER_SECOND", "1.5")
	t.Setenv("WIRE_ADMISSION_BURST_EVENTS", "257")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "WIRE_ADMISSION_BURST_EVENTS") {
		t.Fatalf("oversized burst error = %v", err)
	}
	// The publication-author-viewer pipeline remains unaffected by Wire-only controls.
	t.Setenv("JETSTREAM_PIPELINE_MODE", DefaultPipelineMode)
	if _, err := Load(); err != nil {
		t.Fatalf("non-Wire pipeline rejected Wire-only controls: %v", err)
	}
}

func setRequiredWireAdmission(t *testing.T) {
	t.Helper()
	t.Setenv("WIRE_ADMISSION_RATE_PER_SECOND", "1.5")
	t.Setenv("WIRE_ADMISSION_BURST_EVENTS", "1")
}
