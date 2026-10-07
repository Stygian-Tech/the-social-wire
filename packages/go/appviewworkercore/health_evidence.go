package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"log/slog"
	"strconv"
	"time"
)

type ingestionEvidence struct {
	ReplayState                         *string
	HeartbeatAt, CheckpointAt, OldestAt *time.Time
	Pending, Leased, Retry, DeadLetters int64
	Liveness, Freshness, Completeness   string
	Dependencies                        map[string]string
}

func (h *Host) evidence(ctx context.Context, at time.Time) (ingestionEvidence, error) {
	evidence := ingestionEvidence{Liveness: "unknown", Freshness: "unknown", Completeness: "unknown", Dependencies: map[string]string{}}
	tx, err := h.DB.BeginTx(ctx, nil)
	if err != nil {
		return evidence, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "SET LOCAL statement_timeout='2s'"); err != nil {
		return evidence, err
	}
	err = tx.QueryRowContext(ctx, `WITH actionable AS(
 SELECT count(*)FILTER(WHERE status='pending')::bigint pending,count(*)FILTER(WHERE status='leased')::bigint leased,count(*)FILTER(WHERE status='retry')::bigint retry,min(staged_at) oldest FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND status IN('pending','leased','retry')),
 dead AS(SELECT count(*)::bigint count FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND status='dead_letter'AND reconciled_at IS NULL),
 checkpoint AS(SELECT replay_state,updated_at,(SELECT max(updated_at)FROM appview_ingestion_leases lease WHERE lease.environment=checkpoint.environment AND lease.source_generation=checkpoint.source_generation AND released_at IS NULL AND lease_expires_at>=$3)heartbeat FROM appview_jetstream_checkpoints checkpoint WHERE environment=$1 AND source_generation=$2)
 SELECT checkpoint.replay_state,checkpoint.updated_at,checkpoint.heartbeat,actionable.pending,actionable.leased,actionable.retry,actionable.oldest,dead.count FROM actionable CROSS JOIN dead LEFT JOIN checkpoint ON TRUE`, h.Config.Environment, h.Config.Generation, at).Scan(&evidence.ReplayState, &evidence.CheckpointAt, &evidence.HeartbeatAt, &evidence.Pending, &evidence.Leased, &evidence.Retry, &evidence.OldestAt, &evidence.DeadLetters)
	if err != nil {
		return evidence, err
	}
	var repairQueued, repairRunning, repairFailed int64
	var repairOldest *time.Time
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FILTER(WHERE status='queued')::bigint,count(*) FILTER(WHERE status='running')::bigint,count(*) FILTER(WHERE status='failed')::bigint,min(created_at) FILTER(WHERE status IN('queued','running','failed')) FROM appview_projection_repair_outbox WHERE environment=$1`, h.Config.Environment).Scan(&repairQueued, &repairRunning, &repairFailed, &repairOldest); err != nil {
		return evidence, err
	}
	if repairOldest != nil && repairOldest.After(at) {
		return evidence, errors.New("invalid projection repair backlog evidence")
	}
	if err := tx.Commit(); err != nil {
		return evidence, err
	}
	transport := "missing"
	replay := "missing"
	if evidence.ReplayState != nil {
		replay = *evidence.ReplayState
		evidence.Freshness = "healthy"
		evidence.Completeness = "healthy"
		if evidence.DeadLetters > 0 {
			evidence.Completeness = "unhealthy"
		}
		if evidence.OldestAt != nil {
			age := at.Sub(*evidence.OldestAt)
			if age > 15*time.Minute {
				evidence.Freshness = "unhealthy"
			} else if age > time.Minute {
				evidence.Freshness = "degraded"
			}
		}
	}
	if evidence.HeartbeatAt != nil {
		age := at.Sub(*evidence.HeartbeatAt)
		if age < 0 || age > 30*time.Second {
			transport = "expired"
		} else if replay == "failed" {
			transport = "replay_failed"
			evidence.Liveness = "unhealthy"
		} else if replay == "paused_budget" {
			transport = "paused_budget"
			evidence.Liveness = "degraded"
		} else {
			transport = "ready"
			evidence.Liveness = "healthy"
		}
	}
	pds := "disabled"
	replaySupport := "disabled_by_worker_role"
	if h.Config.Role == "coordinator" {
		replaySupport = "enabled_durable_v2"
		if h.Config.RecoveryEnabled {
			pds = "enabled_diagnostic_only"
		}
	}
	age := func(value *time.Time) string {
		if value == nil {
			return "missing"
		}
		seconds := at.Sub(*value).Seconds()
		if seconds < 0 {
			return "invalid"
		}
		if seconds > 31536000 {
			return "31536000+"
		}
		return strconv.FormatInt(int64(seconds), 10)
	}

	evidence.Dependencies = map[string]string{"appview_database": "ready", "operations_database": "ready", "worker_role": h.Config.Role, "ingestion_transport": transport, "ingestion_source": "jetstream_v2_inbox", "ingestion_authority": "jetstream_v2_inbox", "jetstream_transport": "disabled", "jetstream_role": "authoritative_unverified", "tap_transport": "disabled", "tap_role": "disabled", "tap_consumer_mode": "disabled", "tap_validation_support": "disabled", "tap_verified_resync": "unsupported", "jetstream_replay": replaySupport, "jetstream_v2_source_generation": h.Config.Generation, "pds_reconciliation": pds, "jetstream_v2_replay_state": replay, "jetstream_v2_inbox_pending": strconv.FormatInt(evidence.Pending, 10), "jetstream_v2_inbox_leased": strconv.FormatInt(evidence.Leased, 10), "jetstream_v2_inbox_retrying": strconv.FormatInt(evidence.Retry, 10), "jetstream_v2_dead_letters": strconv.FormatInt(evidence.DeadLetters, 10), "jetstream_v2_intake_heartbeat_age_seconds": age(evidence.HeartbeatAt), "jetstream_v2_checkpoint_age_seconds": age(evidence.CheckpointAt), "jetstream_v2_inbox_oldest_actionable_age_seconds": age(evidence.OldestAt), "projection_repair_backlog": "disabled", "projection_repair_queued_count": "0", "projection_repair_running_count": "0", "projection_repair_failed_count": "0", "projection_repair_oldest_actionable_at": "none", "projection_repair_oldest_actionable_age_seconds": "none", "projection_repair_observed_at": at.UTC().Format(time.RFC3339), "runtime": "go"}
	evidence.Dependencies["projection_repair_backlog"] = "not_authoritative"
	if repairQueued+repairRunning+repairFailed > 0 {
		evidence.Dependencies["projection_repair_backlog"] = "pending"
		if repairFailed > 0 {
			evidence.Dependencies["projection_repair_backlog"] = "failed"
		} else if repairOldest != nil && at.Sub(*repairOldest) > 5*time.Second {
			evidence.Dependencies["projection_repair_backlog"] = "overdue"
		}
	}
	evidence.Dependencies["projection_repair_queued_count"] = strconv.FormatInt(repairQueued, 10)
	evidence.Dependencies["projection_repair_running_count"] = strconv.FormatInt(repairRunning, 10)
	evidence.Dependencies["projection_repair_failed_count"] = strconv.FormatInt(repairFailed, 10)
	if repairOldest != nil {
		evidence.Dependencies["projection_repair_oldest_actionable_at"] = repairOldest.UTC().Format(time.RFC3339)
		evidence.Dependencies["projection_repair_oldest_actionable_age_seconds"] = fmt.Sprintf("%.3f", at.Sub(*repairOldest).Seconds())
	}
	if h.Telemetry != nil {
		snapshot := h.Telemetry.Snapshot()
		applyTelemetryEvidence(&evidence, snapshot, time.Now())
	}
	return evidence, nil
}
func (h *Host) runHeartbeat(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	started := time.Now()
	for {
		at := time.Now()
		evidence, err := h.evidence(ctx, at)
		if err == nil {
			err = h.publishHeartbeat(ctx, evidence, authority, started, at)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			slog.Warn("AppView heartbeat evidence failed", "error", err)
		}
		if err := workerPause(ctx, 5*time.Second); err != nil {
			return err
		}
	}
}
func (h *Host) publishHeartbeat(ctx context.Context, evidence ingestionEvidence, authority *operationscore.RoleLeaseAuthority, started, at time.Time) error {
	service := "projection-pool-appview"
	if h.Config.Role == "coordinator" {
		service = "coordinator-appview"
	}
	if authority != nil {
		evidence.Dependencies["coordinator_authority"] = "active"
		evidence.Dependencies["coordinator_role"] = authority.Role
		evidence.Dependencies["coordinator_owner_id"] = authority.OwnerID
		evidence.Dependencies["coordinator_fencing_token"] = strconv.FormatInt(authority.FencingToken, 10)
	}
	dependencies, err := json.Marshal(evidence.Dependencies)
	if err != nil {
		return err
	}
	tx, err := h.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, "SET LOCAL statement_timeout='2s'"); err != nil {
		return err
	}
	if authority != nil {
		if err := operationscore.LockRoleLeaseFence(ctx, tx, *authority, false); err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO operations_service_state(service,environment,instance_id,liveness,readiness,freshness,completeness,dependency_state,version,started_at,heartbeat_at)VALUES($1,$2,$3,$4,$4,$5,$6,$7::jsonb,$8,$9,$10)ON CONFLICT(service,environment,instance_id)DO UPDATE SET liveness=EXCLUDED.liveness,readiness=EXCLUDED.readiness,freshness=EXCLUDED.freshness,completeness=EXCLUDED.completeness,dependency_state=EXCLUDED.dependency_state,version=EXCLUDED.version,heartbeat_at=EXCLUDED.heartbeat_at`, service, h.Config.Environment, h.Config.InstanceID, evidence.Liveness, evidence.Freshness, evidence.Completeness, string(dependencies), h.Config.Version, started, at)
	if err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if h.Telemetry != nil {
		for dimension, state := range map[string]string{"liveness": evidence.Liveness, "readiness": evidence.Liveness, "freshness": evidence.Freshness, "completeness": evidence.Completeness} {
			dimensions := map[string]string{"service": service, "dimension": dimension, "state": state}
			if authority != nil {
				dimensions["coordinator_authority"] = "active"
				dimensions["coordinator_role"] = authority.Role
			}
			h.Telemetry.Enqueue(MetricSample{Name: "socialwire.service.health.samples_total", Value: 1, Dimensions: dimensions, At: at})
		}
	}
	return nil
}
func (h *Host) checkReadiness(ctx context.Context) error {
	service := "projection-pool-appview"
	if h.Config.Role == "coordinator" {
		service = "coordinator-appview"
	}
	var liveness, readiness, freshness, completeness string
	var heartbeat time.Time
	err := h.DB.QueryRowContext(ctx, `SELECT liveness,readiness,freshness,completeness,heartbeat_at FROM operations_service_state WHERE service=$1 AND environment=$2 AND instance_id=$3`, service, h.Config.Environment, h.Config.InstanceID).Scan(&liveness, &readiness, &freshness, &completeness, &heartbeat)
	if errors.Is(err, sql.ErrNoRows) {
		return errors.New("missing ingestion heartbeat")
	}
	if err != nil {
		return err
	}
	age := time.Since(heartbeat)
	if age < -5*time.Second || age > 15*time.Second {
		return errors.New("stale ingestion heartbeat")
	}
	if liveness != "healthy" || readiness != "healthy" || freshness != "healthy" || completeness != "healthy" {
		return fmt.Errorf("ingestion evidence unhealthy: %s/%s/%s/%s", liveness, readiness, freshness, completeness)
	}
	return nil
}
