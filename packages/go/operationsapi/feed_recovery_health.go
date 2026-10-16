package operationsapi

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

const feedRecoveryProgressWindow = 10 * time.Minute

type feedRecoverySource struct {
	Generation, State                         string
	Wire                                      bool
	AcquiredAt                                time.Time
	LastEventAt, LastStagedAt, LastProgressAt *time.Time
	LastSequence, SealedSequence              *int64
	JobState                                  string
	JobCreatedAt, JobProgressAt               *time.Time
	JobAfter, JobBefore, JobLast              *int64
}

type feedRecoveryGeneration struct {
	GeneratedAt, ExpiresAt time.Time
}

type feedRecoveryHealth struct {
	Sources                                               []feedRecoverySource
	Generation                                            *feedRecoveryGeneration
	Truncated                                             bool
	BudgetPaused, Blocked, Expired, Degraded, Quarantined int
}

// Begin with the live lease expiry index, then point-join checkpoints and Wire
// anchors. Historical and released generations cannot create progress alarms.
func (s *PostgresStore) loadFeedRecoveryHealth(parent context.Context, at time.Time) (*feedRecoveryHealth, error) {
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	rows, err := s.DB.Query(ctx, `SELECT lease.source_generation,COALESCE(checkpoint.replay_state,''),lease.acquired_at,checkpoint.last_staged_event_at,checkpoint.last_staged_at,checkpoint.replay_last_progress_at,checkpoint.last_staged_seq,checkpoint.replay_sealed_seq,EXISTS(SELECT 1 FROM wire_ingestion_recovery_anchors anchor WHERE anchor.environment=lease.environment AND anchor.source_generation=lease.source_generation LIMIT 1),COALESCE(job.status,''),job.created_at,job.last_progress_at,job.after_seq,job.before_seq,job.last_staged_seq FROM appview_ingestion_leases lease LEFT JOIN appview_jetstream_checkpoints checkpoint ON checkpoint.environment=lease.environment AND checkpoint.source_generation=lease.source_generation LEFT JOIN LATERAL(SELECT status,created_at,last_progress_at,after_seq,before_seq,last_staged_seq FROM ingestion_recovery_jobs job WHERE job.environment=lease.environment AND job.source_generation=lease.source_generation AND job.status<>'complete' ORDER BY job.created_at LIMIT 1)job ON TRUE WHERE lease.environment=$1 AND lease.released_at IS NULL AND lease.lease_expires_at>$2 ORDER BY lease.lease_expires_at DESC,lease.lease_name LIMIT 32`, s.Environment, at)
	if err != nil {
		return nil, err
	}
	health := &feedRecoveryHealth{Sources: []feedRecoverySource{}}
	for rows.Next() {
		var source feedRecoverySource
		if err := rows.Scan(&source.Generation, &source.State, &source.AcquiredAt, &source.LastEventAt, &source.LastStagedAt, &source.LastProgressAt, &source.LastSequence, &source.SealedSequence, &source.Wire, &source.JobState, &source.JobCreatedAt, &source.JobProgressAt, &source.JobAfter, &source.JobBefore, &source.JobLast); err != nil {
			rows.Close()
			return nil, err
		}
		health.Sources = append(health.Sources, source)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	// Reaching the bound is explicit degraded evidence rather than pretending
	// all active lanes have been inspected.
	health.Truncated = len(health.Sources) == 32
	// Recovery state remains actionable even if the live checkpoint is healthy,
	// or an expired/blocked controller has released its lease. Counts are bounded
	// lower bounds; never read quarantined payloads or error strings into alerts.
	err = s.DB.QueryRow(ctx, feedRecoveryIssuesSQL, s.Environment).Scan(&health.BudgetPaused, &health.Blocked, &health.Expired, &health.Degraded, &health.Quarantined)
	if err != nil {
		return nil, err
	}
	var generation feedRecoveryGeneration
	err = s.DB.QueryRow(ctx, `SELECT generation.generated_at,generation.expires_at FROM wire_feed_state state JOIN wire_rank_generations generation ON generation.generation_id=state.active_generation_id WHERE state.feed_key='wire' AND state.language_bucket='und' AND generation.status='committed' LIMIT 1`).Scan(&generation.GeneratedAt, &generation.ExpiresAt)
	if err == nil {
		health.Generation = &generation
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	return health, nil
}

const feedRecoveryIssuesSQL = `SELECT
 (SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_controllers WHERE environment=$1 AND status='paused_budget' LIMIT 32)c)+(SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_jobs WHERE environment=$1 AND status IN('paused_budget','paused_daily') LIMIT 32)j),
 (SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_controllers WHERE environment=$1 AND status='blocked_discontinuity' LIMIT 32)c)+(SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_jobs WHERE environment=$1 AND status='blocked_discontinuity' LIMIT 32)j),
 (SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_controllers WHERE environment=$1 AND status='expired' LIMIT 32)c)+(SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_jobs WHERE environment=$1 AND status='expired' LIMIT 32)j),
 (SELECT count(*) FROM(SELECT 1 FROM ingestion_recovery_controllers WHERE environment=$1 AND status='degraded' LIMIT 32)c),
 (SELECT count(*) FROM(SELECT 1 FROM ingestion_poison_records WHERE environment=$1 AND status<>'repaired' LIMIT 32)p)`

func feedRecoveryAlertConditions(health *feedRecoveryHealth, unavailable bool, at time.Time) []AlertCondition {
	if health == nil && !unavailable {
		return nil
	}
	rule := func(active bool, name, severity, summary string, evidence map[string]string) AlertCondition {
		return AlertCondition{Active: active, Rule: name, Key: "feed_recovery:" + name, Severity: severity, Summary: summary, Runbook: "live-process-stalled-ingestion", Evidence: evidence}
	}
	conditions := []AlertCondition{rule(unavailable, "evidence_unavailable", "warning", "Feed recovery health could not be checked within its bounded query budget.", nil)}
	if unavailable || health == nil {
		// Keep previously observed conditions open until fresh evidence can
		// resolve them; health-query failure must not manufacture a recovery.
		return conditions
	}
	conditions = append(conditions, rule(health.Truncated, "source_limit_reached", "warning", "Feed recovery health reached its active-source observation limit.", map[string]string{"source_limit": "32"}))
	budget, stalled, lagged := health.BudgetPaused, 0, 0
	budgetSource, stalledSource, laggedSource := "", "", ""
	wireActive := false
	for _, source := range health.Sources {
		if source.State == "snapshot_complete" {
			continue
		}
		wireActive = wireActive || source.Wire
		if source.State == "paused_budget" {
			budget++
			budgetSource = source.Generation
		}
		progress := source.AcquiredAt
		for _, value := range []*time.Time{source.LastProgressAt, source.LastStagedAt} {
			if value != nil && value.After(progress) {
				progress = *value
			}
		}
		if source.State == "replaying" && source.SealedSequence != nil && (source.LastSequence == nil || *source.SealedSequence > *source.LastSequence) && at.Sub(progress) >= feedRecoveryProgressWindow {
			stalled++
			stalledSource = source.Generation
		}
		// Automatic archive recovery has its own cursor; its live parent may
		// keep advancing normally while this bounded job is stuck.
		jobProgress := source.AcquiredAt
		for _, value := range []*time.Time{source.JobCreatedAt, source.JobProgressAt} {
			if value != nil && value.After(jobProgress) {
				jobProgress = *value
			}
		}
		jobLast := source.JobAfter
		if source.JobLast != nil {
			jobLast = source.JobLast
		}
		if (source.JobState == "pending" || source.JobState == "replaying") && source.JobBefore != nil && jobLast != nil && *source.JobBefore > *jobLast && at.Sub(jobProgress) >= feedRecoveryProgressWindow {
			stalled++
			stalledSource = source.Generation
		}
		if source.Wire && source.State == "live" {
			observed := source.AcquiredAt
			if source.LastEventAt != nil {
				observed = *source.LastEventAt
			}
			if at.Sub(observed) >= feedRecoveryProgressWindow {
				lagged++
				laggedSource = source.Generation
			}
		}
	}
	evidence := func(count int, generation string) map[string]string {
		return map[string]string{"affected_records_lower_bound": strconv.Itoa(count), "source_generation": generation, "observed_at": at.UTC().Format(time.RFC3339), "threshold_seconds": "600"}
	}
	for _, condition := range []AlertCondition{
		rule(budget > 0, "replay_budget_paused", "critical", "Ingestion recovery is paused by a replay budget and requires operator review.", evidence(budget, budgetSource)),
		rule(stalled > 0, "replay_progress_stalled", "critical", "An actively owned replay has a known archive gap and no durable progress for ten minutes.", evidence(stalled, stalledSource)),
		rule(lagged > 0, "wire_event_freshness_delayed", "warning", "An actively owned live Wire source has not staged a recent event. Source quietness does not prove a stuck cursor.", evidence(lagged, laggedSource)),
	} {
		if condition.Active || !health.Truncated {
			conditions = append(conditions, condition)
		}
	}
	conditions = append(conditions,
		rule(health.Blocked > 0, "recovery_discontinuity_blocked", "critical", "Ingestion recovery found an unresolved source discontinuity; cursor resets require operator review.", evidence(health.Blocked, "")),
		rule(health.Expired > 0, "recovery_window_expired", "critical", "An ingestion recovery window expired before its gap was repaired.", evidence(health.Expired, "")),
		rule(health.Degraded > 0, "recovery_controller_degraded", "warning", "An ingestion recovery controller reports degraded operation.", evidence(health.Degraded, "")),
		rule(health.Quarantined > 0, "poison_records_unresolved", "warning", "Quarantined or expired ingestion records remain unrepaired; live progress does not prove archive completeness.", evidence(health.Quarantined, "")),
	)
	stale, severity, summary := false, "warning", "The Wire's active generation is more than ten minutes old."
	generationEvidence := map[string]string{"observed_at": at.UTC().Format(time.RFC3339)}
	if health.Generation != nil {
		generation := health.Generation
		age := at.Sub(generation.GeneratedAt)
		stale = age >= feedRecoveryProgressWindow || !generation.ExpiresAt.After(at)
		generationEvidence["generated_at"] = generation.GeneratedAt.UTC().Format(time.RFC3339)
		generationEvidence["expires_at"] = generation.ExpiresAt.UTC().Format(time.RFC3339)
		generationEvidence["age_seconds"] = strconv.FormatFloat(age.Seconds(), 'f', 0, 64)
		if !generation.ExpiresAt.After(at) || age >= wirecore.MaximumWireGenerationAge {
			severity, summary = "critical", "The Wire is serving beyond its normal generation lifetime or has exhausted its six-hour last-good ceiling."
		}
	} else if wireActive {
		stale, severity, summary = true, "critical", "Wire ingestion is active but no committed global feed generation is available."
	}
	return append(conditions, rule(stale, "wire_generation_delayed", severity, summary, generationEvidence))
}
