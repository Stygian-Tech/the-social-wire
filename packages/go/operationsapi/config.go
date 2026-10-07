// Package operationsapi ports the independently deployed Operations control plane.
package operationsapi

import (
	"errors"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Environment, InstanceID, DatabaseURL, InternalSecret, WebhookURL, WebhookSecret, FingerprintSecret                                                 string
	Enabled, RecoveryEnabled, AlertDeliveryEnabled, RetentionCatchUpEnabled                                                                            bool
	OperatorDIDs                                                                                                                                       map[string]struct{}
	ReplayRewindMicroseconds, BacklogAlertMicroseconds                                                                                                 int64
	DisconnectAlert, IdleAlert, CommitStale, BackfillStall, BootstrapP95, EntriesP95, UnreadCountsP95, SidebarP95, DatabaseQueryP95, ResponseFreshness time.Duration
	IndexFailureRatio, AppView5xxRatio, ResponseFreshnessRatio                                                                                         float64
	IndexFailureMinimum, AppView5xxMinimumRequests                                                                                                     int
}

func ConfigFromEnvironment(env map[string]string) (Config, error) {
	environment := strings.ToLower(strings.TrimSpace(env["APP_ENV"]))
	if environment != "dev" && environment != "prod" {
		return Config{}, errors.New("APP_ENV must be explicitly set to dev or prod for Operations")
	}
	database := strings.TrimSpace(env["DATABASE_URL"])
	if database == "" {
		return Config{}, errors.New("DATABASE_URL is required for Operations")
	}
	instance, present := env["RAILWAY_REPLICA_ID"]
	if !present {
		instance, _ = os.Hostname()
	}
	secret := strings.TrimSpace(env["OPERATIONS_BACKFILL_FINGERPRINT_SECRET"])
	if secret == "" {
		secret = strings.TrimSpace(env["GATEWAY_OPERATIONS_INTERNAL_SECRET"])
	}
	c := Config{Environment: environment, InstanceID: instance, DatabaseURL: database,
		InternalSecret: strings.TrimSpace(env["GATEWAY_OPERATIONS_INTERNAL_SECRET"]),
		WebhookURL:     strings.TrimSpace(env["OPERATIONS_ALERT_WEBHOOK_URL"]), WebhookSecret: strings.TrimSpace(env["OPERATIONS_ALERT_WEBHOOK_SECRET"]), FingerprintSecret: secret,
		Enabled: configTruthy(env, "OPERATIONS_TELEMETRY_ENABLED", true), RecoveryEnabled: configTruthy(env, "OPERATIONS_RECOVERY_ENABLED", false), AlertDeliveryEnabled: configTruthy(env, "OPERATIONS_ALERT_DELIVERY_ENABLED", false), RetentionCatchUpEnabled: strings.ToLower(env["OPERATIONS_RETENTION_CATCHUP_ENABLED"]) == "true", OperatorDIDs: map[string]struct{}{},
		ReplayRewindMicroseconds: configInt(env, "OPERATIONS_REPLAY_REWIND_MICROSECONDS", 5_000_000), BacklogAlertMicroseconds: configInt(env, "OPERATIONS_BACKLOG_ALERT_MICROSECONDS", 60_000_000),
		DisconnectAlert: configDuration(env, "OPERATIONS_DISCONNECT_ALERT_SECONDS", 120), IdleAlert: configDuration(env, "OPERATIONS_IDLE_ALERT_SECONDS", 300), CommitStale: configDuration(env, "OPERATIONS_COMMIT_STALE_SECONDS", 300), BackfillStall: configDuration(env, "OPERATIONS_BACKFILL_STALL_SECONDS", 600),
		BootstrapP95: configDuration(env, "OPERATIONS_BOOTSTRAP_P95_SECONDS", 5), EntriesP95: configDuration(env, "OPERATIONS_ENTRIES_P95_SECONDS", 2), UnreadCountsP95: configDuration(env, "OPERATIONS_UNREAD_COUNTS_P95_SECONDS", 1.5), SidebarP95: configDuration(env, "OPERATIONS_SIDEBAR_P95_SECONDS", 3), DatabaseQueryP95: configDuration(env, "OPERATIONS_DATABASE_QUERY_P95_SECONDS", 1), ResponseFreshness: configDuration(env, "OPERATIONS_RESPONSE_FRESHNESS_SECONDS", 300),
		IndexFailureRatio: configRatio(env, "OPERATIONS_INDEX_FAILURE_RATIO", 0.01), AppView5xxRatio: configRatio(env, "OPERATIONS_APPVIEW_5XX_RATIO", 0.02), ResponseFreshnessRatio: configRatio(env, "OPERATIONS_RESPONSE_FRESHNESS_RATIO", 0.05), IndexFailureMinimum: int(configInt(env, "OPERATIONS_INDEX_FAILURE_MINIMUM", 10)), AppView5xxMinimumRequests: int(configInt(env, "OPERATIONS_APPVIEW_5XX_MINIMUM_REQUESTS", 20)),
	}
	for _, did := range strings.Split(env["OPERATIONS_OPERATOR_DIDS"], ",") {
		if did = strings.TrimSpace(did); did != "" {
			c.OperatorDIDs[did] = struct{}{}
		}
	}
	return c, nil
}
func configTruthy(env map[string]string, key string, fallback bool) bool {
	value, ok := env[key]
	if !ok {
		return fallback
	}
	switch strings.ToLower(value) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}
func configInt(env map[string]string, key string, fallback int64) int64 {
	n, err := strconv.ParseInt(env[key], 10, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}
func configDuration(env map[string]string, key string, fallback float64) time.Duration {
	n, err := strconv.ParseFloat(env[key], 64)
	if err != nil || n <= 0 || math.IsNaN(n) || math.IsInf(n, 0) || n > float64(math.MaxInt64)/float64(time.Second) {
		n = fallback
	}
	return time.Duration(n * float64(time.Second))
}
func configRatio(env map[string]string, key string, fallback float64) float64 {
	n, err := strconv.ParseFloat(env[key], 64)
	if err != nil || n <= 0 || n > 1 || math.IsNaN(n) {
		return fallback
	}
	return n
}
