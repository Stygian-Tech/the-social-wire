package config

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultHost             = "jetstream.us-west.bsky.network"
	DefaultStreamNSID       = "network.bsky.jetstream.subscribeEvents"
	DefaultCursorKind       = "jetstream_v2_seq"
	DefaultSourceGeneration = "jetstream-v2-us-west-v2"
	DefaultScopePolicy      = "publication-author-viewer-v1"
	DefaultPipelineMode     = "publication-author-viewer-v1"
	WirePipelineMode        = "wire-global-v1"
	WireSourceGeneration    = "wire-global-v3"
	WireScopePolicy         = "wire-global-v3"
	DefaultSegmentStripes   = 4
	WireSegmentStripes      = 1
)

var DefaultCollections = []string{
	"site.standard.document",
	"site.standard.entry",
	"com.standard.document",
	"com.standard.entry",
	"app.skyreader.feed.subscription",
	"site.standard.graph.subscription",
}

var WireCollections = []string{
	"site.standard.document",
	"site.standard.entry",
	"site.standard.publication",
	"site.standard.graph.recommend",
	"app.thesocialwire.wireFeedback",
	"app.bsky.feed.post",
	"app.bsky.feed.like",
	"app.bsky.feed.repost",
	"app.bsky.graph.follow",
}

type Config struct {
	PipelineMode         string
	Environment          string
	DatabaseURL          string
	Host                 string
	StreamNSID           string
	CursorKind           string
	SourceGeneration     string
	Collections          []string
	ScopePolicy          string
	FilterFingerprint    string
	APIKey               string
	Port                 int
	BatchSize            int
	DownloadConcurrency  int
	SegmentStripes       int
	MaxDownloadAttempts  int
	LeaderLeaseName      string
	LeaderLeaseTTL       time.Duration
	TrackedDIDRefresh    time.Duration
	ReplayIncidentBytes  int64
	ReplayDailyBytes     int64
	ReplayBudgetPause    time.Duration
	BackoffMin           time.Duration
	BackoffMax           time.Duration
	WireInboxMaxRows     int64
	WireDatabaseMaxBytes int64
	WireAdmissionPause   time.Duration
	WireAdmissionRate    float64
	WireAdmissionBurst   int
	BootstrapAfterSeq    *uint64
	ReplayBeforeSeq      *uint64
	ReplaySnapshotOnly   bool
}

func Load() (Config, error) {
	pipelineMode := envString("JETSTREAM_PIPELINE_MODE", DefaultPipelineMode)
	defaultCollections := DefaultCollections
	defaultGeneration := DefaultSourceGeneration
	defaultScopePolicy := DefaultScopePolicy
	defaultLeaseName := "jetstream-v2-ingest"
	defaultSegmentStripes := DefaultSegmentStripes
	if pipelineMode == WirePipelineMode {
		defaultCollections = WireCollections
		defaultGeneration = WireSourceGeneration
		defaultScopePolicy = WireScopePolicy
		defaultLeaseName = "wire-global-v3-ingest"
		defaultSegmentStripes = WireSegmentStripes
	}
	collections := envCSV("JETSTREAM_COLLECTIONS", defaultCollections)
	replaySnapshotOnly, err := envBool("JETSTREAM_REPLAY_SNAPSHOT_ONLY", false)
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		PipelineMode:         pipelineMode,
		Environment:          strings.TrimSpace(os.Getenv("APP_ENV")),
		DatabaseURL:          strings.TrimSpace(os.Getenv("DATABASE_URL")),
		Host:                 envString("JETSTREAM_HOST", DefaultHost),
		StreamNSID:           DefaultStreamNSID,
		CursorKind:           DefaultCursorKind,
		SourceGeneration:     envString("JETSTREAM_SOURCE_GENERATION", defaultGeneration),
		Collections:          collections,
		ScopePolicy:          defaultScopePolicy,
		FilterFingerprint:    FilterFingerprint(DefaultStreamNSID, collections, defaultScopePolicy),
		APIKey:               strings.TrimSpace(os.Getenv("JETSTREAM_API_KEY")),
		Port:                 envInt("PORT", 8080),
		BatchSize:            envInt("JETSTREAM_BATCH_SIZE", 256),
		DownloadConcurrency:  envInt("JETSTREAM_DOWNLOAD_CONCURRENCY", 4),
		SegmentStripes:       envInt("JETSTREAM_SEGMENT_STRIPES", defaultSegmentStripes),
		MaxDownloadAttempts:  envInt("JETSTREAM_MAX_DOWNLOAD_ATTEMPTS", 8),
		LeaderLeaseName:      envString("JETSTREAM_LEADER_LEASE_NAME", defaultLeaseName),
		LeaderLeaseTTL:       envDuration("JETSTREAM_LEADER_LEASE_TTL", 30*time.Second),
		TrackedDIDRefresh:    envDuration("JETSTREAM_TRACKED_DID_REFRESH", time.Minute),
		ReplayIncidentBytes:  envInt64("JETSTREAM_REPLAY_INCIDENT_BYTES", 5<<30),
		ReplayDailyBytes:     envInt64("JETSTREAM_REPLAY_DAILY_BYTES", 25<<30),
		ReplayBudgetPause:    envDuration("JETSTREAM_REPLAY_BUDGET_PAUSE", 15*time.Minute),
		BackoffMin:           envDuration("JETSTREAM_BACKOFF_MIN", 250*time.Millisecond),
		BackoffMax:           envDuration("JETSTREAM_BACKOFF_MAX", 30*time.Second),
		WireInboxMaxRows:     envInt64("WIRE_INBOX_MAX_ROWS", 5_000_000),
		WireDatabaseMaxBytes: envInt64("WIRE_DATABASE_MAX_BYTES", 80<<30),
		WireAdmissionPause:   envDuration("WIRE_ADMISSION_PAUSE", 5*time.Second),
		WireAdmissionRate:    envFloat64("WIRE_ADMISSION_RATE_PER_SECOND", 0),
		WireAdmissionBurst:   envInt("WIRE_ADMISSION_BURST_EVENTS", 1),
		ReplaySnapshotOnly:   replaySnapshotOnly,
	}
	if value := strings.TrimSpace(os.Getenv("JETSTREAM_BOOTSTRAP_AFTER_SEQ")); value != "" {
		seq, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("JETSTREAM_BOOTSTRAP_AFTER_SEQ: %w", err)
		}
		cfg.BootstrapAfterSeq = &seq
	}
	if value := strings.TrimSpace(os.Getenv("JETSTREAM_REPLAY_BEFORE_SEQ")); value != "" {
		seq, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("JETSTREAM_REPLAY_BEFORE_SEQ: %w", err)
		}
		cfg.ReplayBeforeSeq = &seq
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	var problems []error
	if c.PipelineMode != DefaultPipelineMode && c.PipelineMode != WirePipelineMode {
		problems = append(problems, fmt.Errorf("unsupported JETSTREAM_PIPELINE_MODE %q", c.PipelineMode))
	}
	if c.Environment != "dev" && c.Environment != "prod" {
		problems = append(problems, errors.New("APP_ENV must be dev or prod"))
	}
	if c.DatabaseURL == "" {
		problems = append(problems, errors.New("DATABASE_URL is required"))
	}
	if c.Host == "" {
		problems = append(problems, errors.New("JETSTREAM_HOST is required"))
	}
	if c.SourceGeneration == "" {
		problems = append(problems, errors.New("JETSTREAM_SOURCE_GENERATION is required"))
	}
	if len(c.Collections) == 0 {
		problems = append(problems, errors.New("at least one JETSTREAM_COLLECTIONS value is required"))
	} else {
		allowedCollections := DefaultCollections
		if c.PipelineMode == WirePipelineMode {
			allowedCollections = WireCollections
		}
		for _, collection := range c.Collections {
			if !slices.Contains(allowedCollections, collection) {
				problems = append(problems, fmt.Errorf("unsupported JETSTREAM_COLLECTIONS value %q", collection))
			}
		}
	}
	if c.PipelineMode == WirePipelineMode && c.ScopePolicy != WireScopePolicy {
		problems = append(problems, errors.New("Wire pipeline must use the wire-global-v3 scope policy"))
	}
	if c.ScopePolicy == "" {
		problems = append(problems, errors.New("Jetstream scope policy is required"))
	}
	if c.APIKey == "" {
		problems = append(problems, errors.New("JETSTREAM_API_KEY is required for durable archive replay"))
	}
	if c.Port < 1 || c.Port > 65535 {
		problems = append(problems, errors.New("PORT must be between 1 and 65535"))
	}
	if c.BatchSize < 1 || c.BatchSize > 10_000 {
		problems = append(problems, errors.New("JETSTREAM_BATCH_SIZE must be between 1 and 10000"))
	}
	if c.DownloadConcurrency < 1 || c.SegmentStripes < 1 || c.MaxDownloadAttempts < 1 {
		problems = append(problems, errors.New("download concurrency, segment stripes, and max attempts must be positive"))
	}
	if c.LeaderLeaseTTL < 10*time.Second {
		problems = append(problems, errors.New("JETSTREAM_LEADER_LEASE_TTL must be at least 10s"))
	}
	if c.TrackedDIDRefresh < 5*time.Second {
		problems = append(problems, errors.New("JETSTREAM_TRACKED_DID_REFRESH must be at least 5s"))
	}
	if c.ReplayIncidentBytes <= 0 || c.ReplayDailyBytes < c.ReplayIncidentBytes {
		problems = append(problems, errors.New("daily replay budget must be at least the positive incident budget"))
	}
	if c.ReplayBudgetPause < time.Minute {
		problems = append(problems, errors.New("JETSTREAM_REPLAY_BUDGET_PAUSE must be at least 1m"))
	}
	if c.BackoffMin <= 0 || c.BackoffMax < c.BackoffMin {
		problems = append(problems, errors.New("reconnect backoff bounds are invalid"))
	}
	if c.PipelineMode == WirePipelineMode {
		if c.WireInboxMaxRows <= 0 || c.WireDatabaseMaxBytes <= 0 {
			problems = append(problems, errors.New("WIRE_INBOX_MAX_ROWS and WIRE_DATABASE_MAX_BYTES must be positive"))
		}
		if c.WireAdmissionPause < time.Second {
			problems = append(problems, errors.New("WIRE_ADMISSION_PAUSE must be at least 1s"))
		}
		if c.WireAdmissionRate <= 0 || math.IsNaN(c.WireAdmissionRate) || math.IsInf(c.WireAdmissionRate, 0) {
			problems = append(problems, errors.New("WIRE_ADMISSION_RATE_PER_SECOND is required, finite, and positive for the Wire pipeline"))
		}
		if c.WireAdmissionBurst < 1 || c.WireAdmissionBurst > c.BatchSize {
			problems = append(problems, errors.New("WIRE_ADMISSION_BURST_EVENTS must be between 1 and JETSTREAM_BATCH_SIZE"))
		}
	}
	if (c.ReplayBeforeSeq != nil) != c.ReplaySnapshotOnly {
		problems = append(problems, errors.New(
			"JETSTREAM_REPLAY_BEFORE_SEQ and JETSTREAM_REPLAY_SNAPSHOT_ONLY=true are required together",
		))
	}
	if c.ReplayBeforeSeq != nil {
		if *c.ReplayBeforeSeq == 0 {
			problems = append(problems, errors.New("JETSTREAM_REPLAY_BEFORE_SEQ must be positive"))
		}
		if *c.ReplayBeforeSeq > math.MaxInt64 {
			problems = append(problems, errors.New("JETSTREAM_REPLAY_BEFORE_SEQ exceeds the signed 64-bit cursor range"))
		}
		if c.PipelineMode != WirePipelineMode {
			problems = append(problems, errors.New("bounded snapshot replay is supported only by the Wire pipeline"))
		}
		if c.BootstrapAfterSeq == nil {
			problems = append(problems, errors.New(
				"bounded snapshot replay requires JETSTREAM_BOOTSTRAP_AFTER_SEQ as its exclusive lower bound",
			))
		}
		if c.BootstrapAfterSeq != nil && *c.BootstrapAfterSeq > math.MaxInt64 {
			problems = append(problems, errors.New(
				"JETSTREAM_BOOTSTRAP_AFTER_SEQ exceeds the signed 64-bit cursor range",
			))
		}
		if c.BootstrapAfterSeq != nil && *c.ReplayBeforeSeq <= *c.BootstrapAfterSeq {
			problems = append(problems, errors.New(
				"JETSTREAM_REPLAY_BEFORE_SEQ must be greater than JETSTREAM_BOOTSTRAP_AFTER_SEQ",
			))
		}
		defaultGeneration := DefaultSourceGeneration
		if c.PipelineMode == WirePipelineMode {
			defaultGeneration = WireSourceGeneration
		}
		if c.SourceGeneration == defaultGeneration {
			problems = append(problems, errors.New(
				"bounded snapshot replay requires a distinct JETSTREAM_SOURCE_GENERATION",
			))
		}
	}
	return errors.Join(problems...)
}

func FilterFingerprint(streamNSID string, collections []string, scopePolicy string) string {
	canonical := append([]string(nil), collections...)
	for index := range canonical {
		canonical[index] = strings.TrimSpace(canonical[index])
	}
	slices.Sort(canonical)
	canonical = slices.Compact(canonical)
	payload := streamNSID + "\n" + strings.TrimSpace(scopePolicy) + "\n" + strings.Join(canonical, "\n")
	sum := sha256.Sum256([]byte(payload))
	return hex.EncodeToString(sum[:])
}

func envString(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envCSV(name string, fallback []string) []string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return append([]string(nil), fallback...)
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if cleaned := strings.TrimSpace(part); cleaned != "" {
			result = append(result, cleaned)
		}
	}
	return result
}

func envInt(name string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0
	}
	return parsed
}

func envInt64(name string, fallback int64) int64 {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0
	}
	return parsed
}

func envFloat64(name string, fallback float64) float64 {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0
	}
	return parsed
}

func envDuration(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0
	}
	return parsed
}

func envBool(name string, fallback bool) (bool, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s: %w", name, err)
	}
	return parsed, nil
}
