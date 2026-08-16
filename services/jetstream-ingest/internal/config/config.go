package config

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
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
	DefaultSourceGeneration = "jetstream-v2-us-west-v1"
)

var DefaultCollections = []string{
	"site.standard.document",
	"site.standard.entry",
	"com.standard.document",
	"com.standard.entry",
	"app.thesocialwire.entryReadState",
	"app.skyreader.feed.subscription",
	"site.standard.graph.subscription",
}

type Config struct {
	Environment         string
	DatabaseURL         string
	Host                string
	StreamNSID          string
	CursorKind          string
	SourceGeneration    string
	Collections         []string
	FilterFingerprint   string
	APIKey              string
	Port                int
	BatchSize           int
	DownloadConcurrency int
	SegmentStripes      int
	MaxDownloadAttempts int
	LeaderLeaseName     string
	LeaderLeaseTTL      time.Duration
	TrackedDIDRefresh   time.Duration
	ReplayIncidentBytes int64
	ReplayDailyBytes    int64
	ReplayBudgetPause   time.Duration
	BackoffMin          time.Duration
	BackoffMax          time.Duration
	BootstrapAfterSeq   *uint64
}

func Load() (Config, error) {
	collections := envCSV("JETSTREAM_COLLECTIONS", DefaultCollections)
	cfg := Config{
		Environment:         strings.TrimSpace(os.Getenv("APP_ENV")),
		DatabaseURL:         strings.TrimSpace(os.Getenv("DATABASE_URL")),
		Host:                envString("JETSTREAM_HOST", DefaultHost),
		StreamNSID:          DefaultStreamNSID,
		CursorKind:          DefaultCursorKind,
		SourceGeneration:    envString("JETSTREAM_SOURCE_GENERATION", DefaultSourceGeneration),
		Collections:         collections,
		FilterFingerprint:   FilterFingerprint(DefaultStreamNSID, collections),
		APIKey:              strings.TrimSpace(os.Getenv("JETSTREAM_API_KEY")),
		Port:                envInt("PORT", 8080),
		BatchSize:           envInt("JETSTREAM_BATCH_SIZE", 256),
		DownloadConcurrency: envInt("JETSTREAM_DOWNLOAD_CONCURRENCY", 4),
		SegmentStripes:      envInt("JETSTREAM_SEGMENT_STRIPES", 4),
		MaxDownloadAttempts: envInt("JETSTREAM_MAX_DOWNLOAD_ATTEMPTS", 8),
		LeaderLeaseName:     envString("JETSTREAM_LEADER_LEASE_NAME", "jetstream-v2-ingest"),
		LeaderLeaseTTL:      envDuration("JETSTREAM_LEADER_LEASE_TTL", 30*time.Second),
		TrackedDIDRefresh:   envDuration("JETSTREAM_TRACKED_DID_REFRESH", time.Minute),
		ReplayIncidentBytes: envInt64("JETSTREAM_REPLAY_INCIDENT_BYTES", 5<<30),
		ReplayDailyBytes:    envInt64("JETSTREAM_REPLAY_DAILY_BYTES", 25<<30),
		ReplayBudgetPause:   envDuration("JETSTREAM_REPLAY_BUDGET_PAUSE", 15*time.Minute),
		BackoffMin:          envDuration("JETSTREAM_BACKOFF_MIN", 250*time.Millisecond),
		BackoffMax:          envDuration("JETSTREAM_BACKOFF_MAX", 30*time.Second),
	}
	if value := strings.TrimSpace(os.Getenv("JETSTREAM_BOOTSTRAP_AFTER_SEQ")); value != "" {
		seq, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("JETSTREAM_BOOTSTRAP_AFTER_SEQ: %w", err)
		}
		cfg.BootstrapAfterSeq = &seq
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	var problems []error
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
	return errors.Join(problems...)
}

func FilterFingerprint(streamNSID string, collections []string) string {
	canonical := append([]string(nil), collections...)
	for index := range canonical {
		canonical[index] = strings.TrimSpace(canonical[index])
	}
	slices.Sort(canonical)
	canonical = slices.Compact(canonical)
	payload := streamNSID + "\n" + strings.Join(canonical, "\n")
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
