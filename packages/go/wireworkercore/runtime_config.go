package wireworkercore

import (
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type InboxScope struct {
	Environment string
	Generations []string
}

type LabelerEndpoint struct {
	SourceDID string
	BaseURL   *url.URL
}

// RuntimeConfig preserves the existing worker's mode promotion and bounded work limits.
type RuntimeConfig struct {
	DatabaseURL, Role, ActorSecret                                                                                 string
	Cycle                                                                                                          CycleConfig
	Interval                                                                                                       time.Duration
	Labelers                                                                                                       []LabelerEndpoint
	LabelMaximumAge                                                                                                time.Duration
	InboxBatch, InboxConcurrency, CleanupBatch, MetadataBatch, MetadataConcurrency, MaximumConnections             int
	InboxIdle, CleanupIdle, MetadataIdle                                                                           time.Duration
	CleanupEnabled, DeferredRecommendations, DependencyVerification, IncrementalRollups, GlobalCandidateProjection bool
	Scope                                                                                                          *InboxScope
	DependencyEnvironment                                                                                          string
	FinanceMode, SportsMode                                                                                        string
	FinanceRightsConfirmed                                                                                         bool
}

func LoadRuntimeConfig(env map[string]string, role string) (RuntimeConfig, error) {
	c := RuntimeConfig{DatabaseURL: strings.TrimSpace(env["DATABASE_URL"]), Role: role, ActorSecret: strings.TrimSpace(env["WIRE_ACTOR_HMAC_SECRET"]), Cycle: DefaultCycleConfig()}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	if role != "drain" && role != "rank" {
		return c, fmt.Errorf("invalid Wire role %q", role)
	}
	mode := func(key string) (string, error) {
		v := strings.ToLower(env[key])
		if v == "" {
			v = "off"
		}
		if v != "off" && v != "shadow" && v != "api" && v != "visible" {
			return "", fmt.Errorf("invalid %s", key)
		}
		return v, nil
	}
	var err error
	if c.Cycle.Mode, err = mode("WIRE_FEED_MODE"); err != nil {
		return c, err
	}
	if c.FinanceMode, err = mode("FINANCE_FEED_MODE"); err != nil {
		return c, err
	}
	if c.SportsMode, err = mode("SPORTS_FEED_MODE"); err != nil {
		return c, err
	}
	c.FinanceRightsConfirmed = env["FINANCE_CATALOG_RIGHTS_CONFIRMED"] == "true"
	if (c.FinanceMode != "off" && c.FinanceRightsConfirmed || c.SportsMode != "off") && (c.Cycle.Mode == "off" || c.Cycle.Mode == "shadow") {
		c.Cycle.Mode = "api"
	}
	c.Cycle.ExternalSignalMode = strings.ToLower(env["WIRE_EXTERNAL_SIGNAL_MODE"])
	if c.Cycle.ExternalSignalMode == "" {
		c.Cycle.ExternalSignalMode = "off"
	}
	if v := c.Cycle.ExternalSignalMode; v != "off" && v != "shadow" && v != "rank" {
		return c, fmt.Errorf("invalid WIRE_EXTERNAL_SIGNAL_MODE")
	}
	if c.Cycle.Mode != "off" && len([]byte(c.ActorSecret)) < 32 {
		return c, fmt.Errorf("WIRE_ACTOR_HMAC_SECRET must contain at least 32 bytes")
	}
	integer := func(key string, fallback, maximum int) (int, error) {
		v := fallback
		if raw, ok := env[key]; ok {
			var e error
			v, e = strconv.Atoi(raw)
			if e != nil {
				return 0, fmt.Errorf("invalid %s", key)
			}
		}
		if v < 1 || maximum > 0 && v > maximum {
			return 0, fmt.Errorf("invalid %s", key)
		}
		return v, nil
	}
	for _, field := range []struct {
		key               string
		target            *int
		fallback, maximum int
	}{
		{"WIRE_CANDIDATE_LIMIT", &c.Cycle.CandidateLimit, 5000, 0}, {"WIRE_RETENTION_BATCH_SIZE", &c.Cycle.RetentionBatchSize, 5000, 0},
		{"WIRE_INBOX_BATCH_SIZE", &c.InboxBatch, 1000, 5000}, {"WIRE_INBOX_CONCURRENCY", &c.InboxConcurrency, 16, 64},
		{"WIRE_INBOX_CLEANUP_BATCH_SIZE", &c.CleanupBatch, 5000, 20000}, {"WIRE_METADATA_BATCH_SIZE", &c.MetadataBatch, 32, 250},
		{"WIRE_METADATA_CONCURRENCY", &c.MetadataConcurrency, 8, 32}, {"WIRE_POSTGRES_MAX_CONNECTIONS", &c.MaximumConnections, 12, 64},
	} {
		if *field.target, err = integer(field.key, field.fallback, field.maximum); err != nil {
			return c, err
		}
	}
	for _, field := range []struct {
		key               string
		target            *time.Duration
		fallback, maximum int
		unit              time.Duration
	}{
		{"WIRE_RANK_INTERVAL_SECONDS", &c.Interval, 300, 0, time.Second}, {"WIRE_GENERATION_RETENTION_SECONDS", &c.Cycle.GenerationRetention, 3600, 0, time.Second},
		{"WIRE_LABEL_REFRESH_MAX_AGE_SECONDS", &c.LabelMaximumAge, 900, 0, time.Second}, {"WIRE_INBOX_IDLE_MILLISECONDS", &c.InboxIdle, 250, 60000, time.Millisecond},
		{"WIRE_INBOX_CLEANUP_IDLE_MILLISECONDS", &c.CleanupIdle, 1000, 60000, time.Millisecond}, {"WIRE_METADATA_IDLE_MILLISECONDS", &c.MetadataIdle, 1000, 60000, time.Millisecond},
	} {
		v, e := integer(field.key, field.fallback, field.maximum)
		if e != nil {
			return c, e
		}
		if int64(v) > int64(^uint64(0)>>1)/int64(field.unit) {
			return c, fmt.Errorf("duration overflow for %s", field.key)
		}
		*field.target = time.Duration(v) * field.unit
	}
	c.Cycle.LanguageBucket = strings.ToLower(env["WIRE_LANGUAGE_BUCKET"])
	if c.Cycle.LanguageBucket == "" {
		c.Cycle.LanguageBucket = "und"
	}
	for _, field := range []struct {
		key      string
		target   *bool
		fallback bool
	}{
		{"WIRE_INBOX_CLEANUP_ENABLED", &c.CleanupEnabled, true}, {"WIRE_DEFERRED_RECOMMENDATIONS_ENABLED", &c.DeferredRecommendations, false},
		{"WIRE_DEPENDENCY_HYDRATION_ENABLED", &c.DependencyVerification, false}, {"WIRE_SIGNAL_ROLLUP_INCREMENTAL_ENABLED", &c.IncrementalRollups, false},
		{"WIRE_GLOBAL_CANDIDATE_PROJECTION_ENABLED", &c.GlobalCandidateProjection, false},
	} {
		v := field.fallback
		if raw, ok := env[field.key]; ok {
			switch strings.ToLower(raw) {
			case "true":
				v = true
			case "false":
				v = false
			default:
				return c, fmt.Errorf("invalid %s", field.key)
			}
		}
		*field.target = v
	}
	requireEnvironment := func() (string, error) {
		v := strings.TrimSpace(env["APP_ENV"])
		if v != "dev" && v != "prod" {
			return "", fmt.Errorf("APP_ENV must be dev or prod")
		}
		return v, nil
	}
	if raw, ok := env["WIRE_INBOX_SOURCE_GENERATIONS"]; ok {
		e, eerr := requireEnvironment()
		if eerr != nil {
			return c, eerr
		}
		scope := &InboxScope{Environment: e}
		seen := map[string]bool{}
		for _, v := range strings.Split(raw, ",") {
			v = strings.TrimSpace(v)
			if v == "" {
				return c, fmt.Errorf("invalid WIRE_INBOX_SOURCE_GENERATIONS")
			}
			if !seen[v] {
				scope.Generations = append(scope.Generations, v)
				seen[v] = true
			}
		}
		c.Scope = scope
	}
	if c.DependencyVerification && role == "rank" {
		if c.DependencyEnvironment, err = requireEnvironment(); err != nil {
			return c, err
		}
	}
	if role == "rank" {
		raw, ok := env["WIRE_BASELINE_LABELERS"]
		if !ok {
			raw = "did:plc:ar7c4by46qjdydhdevvrndac|https://mod.bsky.app"
		}
		if c.Labelers, err = ParseLabelers(raw); err != nil {
			return c, err
		}
	}
	return c, nil
}

func ParseLabelers(raw string) ([]LabelerEndpoint, error) {
	result := []LabelerEndpoint{}
	seen := map[string]bool{}
	for _, entry := range strings.Split(raw, ",") {
		if entry == "" {
			continue
		}
		parts := strings.SplitN(entry, "|", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid labeler")
		}
		did := strings.TrimSpace(parts[0])
		u, err := url.Parse(strings.TrimSpace(parts[1]))
		if err != nil || !strings.HasPrefix(did, "did:") || len([]byte(did)) > 256 || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || seen[did] {
			return nil, fmt.Errorf("invalid labeler")
		}
		seen[did] = true
		result = append(result, LabelerEndpoint{did, u})
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("at least one baseline labeler is required")
	}
	return result, nil
}
