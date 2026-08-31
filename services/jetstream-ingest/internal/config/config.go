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

type LaneName string

const (
	AppViewLaneName         LaneName = "appview"
	WireLaneName            LaneName = "wire"
	DefaultHost                      = "jetstream.us-west.bsky.network"
	DefaultStreamNSID                = "network.bsky.jetstream.subscribeEvents"
	DefaultCursorKind                = "jetstream_v2_seq"
	DefaultSourceGeneration          = "jetstream-v2-us-west-v2"
	DefaultScopePolicy               = "publication-author-viewer-v1"
	DefaultPipelineMode              = "publication-author-viewer-v1"
	WirePipelineMode                 = "wire-global-v1"
	WireSourceGeneration             = "wire-global-v4"
	WireScopePolicy                  = "wire-global-v4"
	DefaultSegmentStripes            = 4
	WireSegmentStripes               = 1
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
	"at.margin.note",
	"at.margin.reply",
	"at.margin.like",
	"at.margin.collectionItem",
	"at.margin.readingRoom",
	"network.cosmik.card",
	"network.cosmik.connection",
	"network.cosmik.collectionLink",
	"network.cosmik.collectionLinkRemoval",
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
	ExitAfterSnapshot    bool
}

// Lane is one independently leased Jetstream ingestion pipeline.
type Lane struct {
	Name   LaneName
	Config Config
}

// ControllerConfig describes the process-wide listener and the ingestion lanes
// that should run behind it. LegacySingleLane is true when the old flat
// JETSTREAM_* configuration selected the sole lane.
type ControllerConfig struct {
	Port             int
	Lanes            []Lane
	LegacySingleLane bool
}

func Load() (Config, error) {
	pipelineMode := envString("JETSTREAM_PIPELINE_MODE", DefaultPipelineMode)
	return loadLane(pipelineMode, "JETSTREAM_", true)
}

// LoadController loads either the existing single-lane configuration or the
// namespaced multi-lane configuration. The namespaced mode is selected by an
// AppView/Wire enable flag or JETSTREAM_WIRE_LANES; at least one resulting lane
// must be enabled.
func LoadController() (ControllerConfig, error) {
	_, appViewFlagPresent := os.LookupEnv("JETSTREAM_APPVIEW_ENABLED")
	_, wireFlagPresent := os.LookupEnv("JETSTREAM_WIRE_ENABLED")
	_, wireLanesPresent := os.LookupEnv("JETSTREAM_WIRE_LANES")
	if !appViewFlagPresent && !wireFlagPresent && !wireLanesPresent {
		cfg, err := Load()
		if err != nil {
			return ControllerConfig{}, err
		}
		name := AppViewLaneName
		if cfg.PipelineMode == WirePipelineMode {
			name = WireLaneName
		}
		return ControllerConfig{
			Port:             cfg.Port,
			Lanes:            []Lane{{Name: name, Config: cfg}},
			LegacySingleLane: true,
		}, nil
	}

	appViewEnabled, err := envBool("JETSTREAM_APPVIEW_ENABLED", false)
	if err != nil {
		return ControllerConfig{}, err
	}
	wireEnabled, err := envBool("JETSTREAM_WIRE_ENABLED", false)
	if err != nil {
		return ControllerConfig{}, err
	}
	wireLaneSuffixes, err := wireLaneSuffixes()
	if err != nil {
		return ControllerConfig{}, err
	}
	if !appViewEnabled && !wireEnabled && len(wireLaneSuffixes) == 0 {
		return ControllerConfig{}, errors.New(
			"at least one controller lane must be enabled",
		)
	}

	controller := ControllerConfig{Port: envInt("PORT", 8080)}
	if appViewEnabled {
		cfg, loadErr := loadLane(DefaultPipelineMode, "JETSTREAM_APPVIEW_", false)
		if loadErr != nil {
			return ControllerConfig{}, fmt.Errorf("%s lane: %w", AppViewLaneName, loadErr)
		}
		controller.Lanes = append(controller.Lanes, Lane{Name: AppViewLaneName, Config: cfg})
	}
	if wireEnabled {
		cfg, loadErr := loadLane(WirePipelineMode, "JETSTREAM_WIRE_", false)
		if loadErr != nil {
			return ControllerConfig{}, fmt.Errorf("%s lane: %w", WireLaneName, loadErr)
		}
		controller.Lanes = append(controller.Lanes, Lane{Name: WireLaneName, Config: cfg})
	}
	for _, suffix := range wireLaneSuffixes {
		laneName := LaneName("wire-" + strings.ToLower(suffix))
		prefix := "JETSTREAM_WIRE_" + strings.ToUpper(suffix) + "_"
		cfg, loadErr := loadLane(WirePipelineMode, prefix, false)
		if loadErr != nil {
			return ControllerConfig{}, fmt.Errorf("%s lane: %w", laneName, loadErr)
		}
		controller.Lanes = append(controller.Lanes, Lane{Name: laneName, Config: cfg})
	}
	if err := validateControllerLanes(controller.Lanes); err != nil {
		return ControllerConfig{}, err
	}
	for _, lane := range controller.Lanes {
		if lane.Config.ExitAfterSnapshot {
			return ControllerConfig{}, errors.New(
				"snapshot jobs that exit are supported only by legacy single-lane configuration",
			)
		}
	}
	return controller, nil
}

func wireLaneSuffixes() ([]string, error) {
	raw := strings.TrimSpace(os.Getenv("JETSTREAM_WIRE_LANES"))
	if raw == "" {
		return nil, nil
	}
	var result []string
	seen := make(map[string]struct{})
	for _, value := range strings.Split(raw, ",") {
		suffix := strings.TrimSpace(value)
		if suffix == "" {
			return nil, errors.New("JETSTREAM_WIRE_LANES cannot contain empty lane names")
		}
		for _, character := range suffix {
			if (character < 'a' || character > 'z') && (character < '0' || character > '9') {
				return nil, fmt.Errorf(
					"JETSTREAM_WIRE_LANES lane %q must use lowercase letters and digits",
					suffix,
				)
			}
		}
		if _, exists := seen[suffix]; exists {
			return nil, fmt.Errorf("JETSTREAM_WIRE_LANES contains duplicate lane %q", suffix)
		}
		seen[suffix] = struct{}{}
		result = append(result, suffix)
	}
	return result, nil
}

func validateControllerLanes(lanes []Lane) error {
	sourceGenerations := make(map[string]LaneName)
	leaseNames := make(map[string]LaneName)
	for _, lane := range lanes {
		if existing, found := sourceGenerations[lane.Config.SourceGeneration]; found {
			return fmt.Errorf(
				"controller lanes %s and %s share source generation %q",
				existing, lane.Name, lane.Config.SourceGeneration,
			)
		}
		sourceGenerations[lane.Config.SourceGeneration] = lane.Name
		if existing, found := leaseNames[lane.Config.LeaderLeaseName]; found {
			return fmt.Errorf(
				"controller lanes %s and %s share leader lease %q",
				existing, lane.Name, lane.Config.LeaderLeaseName,
			)
		}
		leaseNames[lane.Config.LeaderLeaseName] = lane.Name
	}
	return nil
}

func loadLane(pipelineMode, prefix string, legacy bool) (Config, error) {
	defaultCollections := DefaultCollections
	defaultGeneration := DefaultSourceGeneration
	defaultScopePolicy := DefaultScopePolicy
	defaultLeaseName := "jetstream-v2-ingest"
	defaultSegmentStripes := DefaultSegmentStripes
	if pipelineMode == WirePipelineMode {
		defaultCollections = WireCollections
		defaultGeneration = WireSourceGeneration
		defaultScopePolicy = WireScopePolicy
		defaultLeaseName = "wire-global-v4-ingest"
		defaultSegmentStripes = WireSegmentStripes
	}
	collections := envCSV(prefix+"COLLECTIONS", defaultCollections)
	replaySnapshotOnly, err := envBool(prefix+"REPLAY_SNAPSHOT_ONLY", false)
	if err != nil {
		return Config{}, err
	}
	exitAfterSnapshot, err := envBool(prefix+"EXIT_AFTER_SNAPSHOT", false)
	if err != nil {
		return Config{}, err
	}
	hostFallback := DefaultHost
	apiKeyFallback := ""
	if !legacy {
		hostFallback = envString("JETSTREAM_HOST", DefaultHost)
		apiKeyFallback = strings.TrimSpace(os.Getenv("JETSTREAM_API_KEY"))
	}
	cfg := Config{
		PipelineMode:         pipelineMode,
		Environment:          strings.TrimSpace(os.Getenv("APP_ENV")),
		DatabaseURL:          strings.TrimSpace(os.Getenv("DATABASE_URL")),
		Host:                 envString(prefix+"HOST", hostFallback),
		StreamNSID:           DefaultStreamNSID,
		CursorKind:           DefaultCursorKind,
		SourceGeneration:     envString(prefix+"SOURCE_GENERATION", defaultGeneration),
		Collections:          collections,
		ScopePolicy:          defaultScopePolicy,
		FilterFingerprint:    FilterFingerprint(DefaultStreamNSID, collections, defaultScopePolicy),
		APIKey:               envString(prefix+"API_KEY", apiKeyFallback),
		Port:                 envInt("PORT", 8080),
		BatchSize:            envInt(prefix+"BATCH_SIZE", 256),
		DownloadConcurrency:  envInt(prefix+"DOWNLOAD_CONCURRENCY", 4),
		SegmentStripes:       envInt(prefix+"SEGMENT_STRIPES", defaultSegmentStripes),
		MaxDownloadAttempts:  envInt(prefix+"MAX_DOWNLOAD_ATTEMPTS", 8),
		LeaderLeaseName:      envString(prefix+"LEADER_LEASE_NAME", defaultLeaseName),
		LeaderLeaseTTL:       envDuration(prefix+"LEADER_LEASE_TTL", 30*time.Second),
		TrackedDIDRefresh:    envDuration(prefix+"TRACKED_DID_REFRESH", time.Minute),
		ReplayIncidentBytes:  envInt64(prefix+"REPLAY_INCIDENT_BYTES", 5<<30),
		ReplayDailyBytes:     envInt64(prefix+"REPLAY_DAILY_BYTES", 25<<30),
		ReplayBudgetPause:    envDuration(prefix+"REPLAY_BUDGET_PAUSE", 15*time.Minute),
		BackoffMin:           envDuration(prefix+"BACKOFF_MIN", 250*time.Millisecond),
		BackoffMax:           envDuration(prefix+"BACKOFF_MAX", 30*time.Second),
		WireInboxMaxRows:     envInt64(wireVariable(prefix, legacy, "INBOX_MAX_ROWS"), 5_000_000),
		WireDatabaseMaxBytes: envInt64(wireVariable(prefix, legacy, "DATABASE_MAX_BYTES"), 80<<30),
		WireAdmissionPause:   envDuration(wireVariable(prefix, legacy, "ADMISSION_PAUSE"), 5*time.Second),
		WireAdmissionRate:    envFloat64(wireVariable(prefix, legacy, "ADMISSION_RATE_PER_SECOND"), 0),
		WireAdmissionBurst:   envInt(wireVariable(prefix, legacy, "ADMISSION_BURST_EVENTS"), 1),
		ReplaySnapshotOnly:   replaySnapshotOnly,
		ExitAfterSnapshot:    exitAfterSnapshot,
	}
	if value := strings.TrimSpace(os.Getenv(prefix + "BOOTSTRAP_AFTER_SEQ")); value != "" {
		seq, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("%sBOOTSTRAP_AFTER_SEQ: %w", prefix, err)
		}
		cfg.BootstrapAfterSeq = &seq
	}
	if value := strings.TrimSpace(os.Getenv(prefix + "REPLAY_BEFORE_SEQ")); value != "" {
		seq, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return Config{}, fmt.Errorf("%sREPLAY_BEFORE_SEQ: %w", prefix, err)
		}
		cfg.ReplayBeforeSeq = &seq
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func wireVariable(prefix string, legacy bool, suffix string) string {
	if legacy {
		return "WIRE_" + suffix
	}
	return prefix + suffix
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
		problems = append(problems, errors.New("Wire pipeline must use the wire-global-v4 scope policy"))
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
	if c.ExitAfterSnapshot && !c.ReplaySnapshotOnly {
		problems = append(problems, errors.New(
			"JETSTREAM_EXIT_AFTER_SNAPSHOT=true requires bounded snapshot replay",
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
