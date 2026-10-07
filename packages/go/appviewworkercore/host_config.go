package appviewworkercore

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type HostConfig struct {
	Version, Role, Environment, InstanceID, Generation, IntakeLease                                                     string
	Concurrency                                                                                                         int
	LeaseDuration, PollInterval, AppliedRetention, DeadLetterRetention, RestoreTimeout, ContentRetention, ReadRetention time.Duration
	RSSPoll                                                                                                             bool
	RSSInterval                                                                                                         time.Duration
	RSSLimit, MaximumRSSItems, RecoveryRecordBudget                                                                     int
	PDSIdleEviction                                                                                                     bool
	PDSIdleDays                                                                                                         float64
	TelemetryEnabled                                                                                                    bool
	RecoveryEnabled                                                                                                     bool
}

func hostConfiguration(environment map[string]string, role string) (HostConfig, error) {
	if role != "projection" && role != "coordinator" {
		return HostConfig{}, errors.New("invalid AppView worker role")
	}
	if !hostFlag(environment["ENABLE_THIN_APPVIEW"], false) {
		return HostConfig{}, errors.New("ENABLE_THIN_APPVIEW must be true")
	}
	mode := strings.ToLower(strings.TrimSpace(environment["THIN_APPVIEW_JETSTREAM_MODE"]))
	if mode != "v2_authoritative" {
		return HostConfig{}, fmt.Errorf("Go AppView host requires v2_authoritative, got %q", mode)
	}
	if tap := strings.TrimSpace(environment["TAP_CONSUMER_MODE"]); tap != "" && tap != "disabled" {
		return HostConfig{}, errors.New("retired Tap authority cannot run alongside Go durable inbox projection")
	}
	env := environment["APP_ENV"]
	if env != "dev" && env != "prod" {
		return HostConfig{}, errors.New("APP_ENV must identify dev or prod")
	}
	instance := environment["OPERATIONS_INSTANCE_ID"]
	if instance == "" {
		instance = environment["RAILWAY_REPLICA_ID"]
	}
	if instance == "" {
		token, err := newSnapshotToken()
		if err != nil {
			return HostConfig{}, err
		}
		instance = "go-appview-" + token
	}
	generation := environment["JETSTREAM_SOURCE_GENERATION"]
	if generation == "" {
		generation = "jetstream-v2-us-west-v2"
	}
	lease := environment["JETSTREAM_LEADER_LEASE_NAME"]
	if lease == "" {
		lease = "jetstream-v2-ingest"
	}
	c := HostConfig{TelemetryEnabled: hostFlag(environment["OPERATIONS_TELEMETRY_ENABLED"], true), Version: environment["RAILWAY_DEPLOYMENT_ID"], Role: role, Environment: env, InstanceID: instance, Generation: generation, IntakeLease: lease,
		Concurrency: hostInt(environment, "THIN_APPVIEW_INGESTION_INBOX_MAX_CONCURRENCY", 8), LeaseDuration: hostSeconds(environment, "THIN_APPVIEW_INGESTION_INBOX_LEASE_SECONDS", 60), PollInterval: time.Duration(hostInt(environment, "THIN_APPVIEW_INGESTION_INBOX_POLL_MILLISECONDS", 250)) * time.Millisecond,
		AppliedRetention: hostSeconds(environment, "THIN_APPVIEW_INGESTION_INBOX_APPLIED_RETENTION_SECONDS", 7*86400), DeadLetterRetention: hostSeconds(environment, "THIN_APPVIEW_INGESTION_INBOX_DEAD_LETTER_RETENTION_SECONDS", 30*86400), RestoreTimeout: hostSeconds(environment, "THIN_APPVIEW_REPOSITORY_RESTORE_TIMEOUT_SECONDS", 120), ContentRetention: hostSeconds(environment, "THIN_APPVIEW_CONTENT_TTL_SECONDS", 30*86400), ReadRetention: hostSeconds(environment, "THIN_APPVIEW_READ_MARK_TTL_SECONDS", 180*86400),
		RSSPoll: hostFlag(environment["THIN_APPVIEW_RSS_FEED_POLL_ENABLED"], true), RSSInterval: hostSeconds(environment, "THIN_APPVIEW_RSS_FEED_POLL_INTERVAL_SECONDS", 1800), RSSLimit: hostInt(environment, "THIN_APPVIEW_RSS_FEED_POLL_FEED_LIMIT", 20), MaximumRSSItems: hostInt(environment, "THIN_APPVIEW_MAX_RSS_ITEMS_PER_FEED", 200), RecoveryRecordBudget: hostInt(environment, "THIN_APPVIEW_MAX_ENROLL_RECORDS_PER_AUTHOR", 2000), PDSIdleEviction: environment["THIN_APPVIEW_PDS_READ_STATE_EVICTION_ENABLED"] == "true", PDSIdleDays: 7, RecoveryEnabled: hostFlag(environment["OPERATIONS_RECOVERY_ENABLED"], false)}
	c.Concurrency = max(1, min(c.Concurrency, 256))
	c.LeaseDuration = max(5*time.Second, c.LeaseDuration)
	c.PollInterval = max(25*time.Millisecond, c.PollInterval)
	c.AppliedRetention = max(time.Minute, c.AppliedRetention)
	c.DeadLetterRetention = max(time.Minute, c.DeadLetterRetention)
	if value, err := strconv.ParseFloat(environment["THIN_APPVIEW_PDS_READ_STATE_IDLE_DAYS"], 64); err == nil {
		c.PDSIdleDays = max(7, value)
	}
	return c, nil
}
func hostFlag(value string, fallback bool) bool {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "1", "yes", "on":
		return true
	default:
		return false
	}
}
func hostInt(env map[string]string, key string, fallback int) int {
	if value, err := strconv.Atoi(env[key]); err == nil {
		return value
	}
	return fallback
}
func hostSeconds(env map[string]string, key string, fallback float64) time.Duration {
	if value, err := strconv.ParseFloat(env[key], 64); err == nil && value > 0 {
		return time.Duration(value * float64(time.Second))
	}
	return time.Duration(fallback * float64(time.Second))
}
