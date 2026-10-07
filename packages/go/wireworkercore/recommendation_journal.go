package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type recommendationEntry struct {
	Environment, Generation            string
	Sequence                           int64
	Host, Cursor, Repo, URI, Operation string
	Revision, CID                      sql.NullString
	Time                               time.Time
	Actor                              string
	Subject                            sql.NullString
	Status                             string
	Attempts                           int
	RequiresVerification               bool
}

func (e recommendationEntry) eventKey() string {
	return fmt.Sprintf("%s:%s:%d", e.Environment, e.Generation, e.Sequence)
}
func (e recommendationEntry) transportKey() string {
	return fmt.Sprintf("transport:%s:%s:%s:%d", e.Environment, e.Host, e.Cursor, e.Sequence)
}

type PostgresRecommendationJournal struct {
	DB                     *sql.DB
	DependencyVerification bool
	mu                     sync.Mutex
	recoveryPositions      map[string]*recommendationPosition
}

func (j *PostgresRecommendationJournal) Process(ctx context.Context, event InboxEvent, hasher *wirecore.ActorHasher, at time.Time, deferUnresolved bool) (outcome InboxOutcome, applicationError error) {
	if event.Collection.String != "site.standard.graph.recommend" || event.SourceURI() == "" || event.Operation.String != "create" && event.Operation.String != "update" && event.Operation.String != "delete" {
		return "", ErrMalformedDocument
	}
	actor, err := hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return "", err
	}
	tx, err := j.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer func() {
		if e := tx.Rollback(); e != nil && e != sql.ErrTxDone {
			applicationError = fmt.Errorf("recommendation rollback uncertain: %w", e)
		}
	}()
	var revision, cid sql.NullString
	var attempts int
	err = tx.QueryRowContext(ctx, `SELECT repo_rev,record_cid,attempt_count FROM wire_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq=$3 AND status='leased' AND lease_token=$4 AND lease_expires_at>$5 FOR UPDATE`, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.LeaseToken, at).Scan(&revision, &cid, &attempts)
	if err == sql.ErrNoRows {
		return InboxLeaseLost, nil
	}
	if err != nil {
		return "", err
	}
	if err = lockRecommendationRecord(ctx, tx, event.Repository.Environment, event.Repository.RepoDID, event.SourceURI(), false); err != nil {
		return "", err
	}
	var subject *string
	if event.Operation.String != "delete" {
		var document map[string]any
		if json.Unmarshal([]byte(event.PayloadJSON), &document) == nil {
			record := object(object(document["commit"])["record"])
			text := recordString(record, "document")
			if text == "" {
				text = recordString(record, "subject")
				if text == "" {
					text = recordString(object(record["subject"]), "uri")
				}
			}
			subject = stringPointer(text)
		}
		if subject == nil {
			accepted, e := FinishInbox(ctx, tx, event, "dead_letter", at, stringPointer("malformed_event"), at)
			if e != nil {
				return "", e
			}
			if !accepted {
				return InboxLeaseLost, nil
			}
			if e = tx.Commit(); e != nil {
				return "", e
			}
			return InboxTerminal, nil
		}
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO wire_recommendation_journal(environment,source_generation,seq,source_host,cursor_kind,repo_did,source_uri,operation,repo_rev,record_cid,payload,event_time,actor_key_hash,subject_uri,next_attempt_at,created_at,updated_at,dependency_verification_required) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12,$13,$14,$15,$15,$15,$16) ON CONFLICT(environment,source_generation,seq) DO UPDATE SET dependency_verification_required=TRUE WHERE wire_recommendation_journal.status='pending' AND NOT wire_recommendation_journal.dependency_verification_required AND EXCLUDED.dependency_verification_required`, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.SourceHost, event.CursorKind, event.Repository.RepoDID, event.SourceURI(), event.Operation, revision, cid, event.PayloadJSON, event.EventTime, actor, subject, at, attempts > 1)
	if err != nil {
		return "", err
	}
	entry, err := readRecommendation(ctx, tx, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence)
	if err != nil {
		return "", err
	}
	if entry == nil {
		return "", ErrMalformedDocument
	}
	status, err := j.reconcile(ctx, tx, *entry, at)
	if err != nil {
		return "", err
	}
	inboxStatus := "deferred"
	outcome = InboxDeferred
	var applied *time.Time
	switch status {
	case "resolved", "deleted":
		inboxStatus = "applied"
		outcome = InboxApplied
		applied = &at
	case "superseded", "expired":
		inboxStatus = "superseded"
		outcome = InboxTerminal
	default:
		if !deferUnresolved {
			inboxStatus = "retry"
			outcome = InboxRetry
		}
	}
	var reason *string
	if inboxStatus != "applied" {
		reason = stringPointer("recommendation_" + status)
	}
	retry, expiry := at, at.Add(300*time.Second)
	if inboxStatus == "retry" {
		retry = at.Add(30 * time.Second)
		expiry = time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	result, err := tx.ExecContext(ctx, `UPDATE wire_ingestion_inbox SET status=$1,applied_at=$2,dead_lettered_at=NULL,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,failure_category=$3,failure_reason=$3,next_attempt_at=$4,expires_at=$5,updated_at=$6 WHERE environment=$7 AND source_generation=$8 AND seq=$9 AND status='leased' AND lease_token=$10`, inboxStatus, applied, reason, retry, expiry, at, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.LeaseToken)
	if err != nil {
		return "", err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return "", err
	}
	if n != 1 {
		return InboxLeaseLost, nil
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return outcome, nil
}
func lockRecommendationRecord(ctx context.Context, tx *sql.Tx, environment, repo, uri string, try bool) error {
	account := "wire-recommendation-account:" + environment + ":" + repo
	if try {
		var acquired bool
		if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))`, account).Scan(&acquired); err != nil {
			return err
		}
		if !acquired {
			return sql.ErrNoRows
		}
	} else {
		if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, account); err != nil {
			return err
		}
	}
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, uri)
	return err
}
func readRecommendation(ctx context.Context, tx *sql.Tx, environment, generation string, sequence int64) (*recommendationEntry, error) {
	var e recommendationEntry
	err := tx.QueryRowContext(ctx, `SELECT environment,source_generation,seq,source_host,cursor_kind,repo_did,source_uri,operation,repo_rev,record_cid,event_time,actor_key_hash,subject_uri,status,attempt_count,dependency_verification_required FROM wire_recommendation_journal WHERE environment=$1 AND source_generation=$2 AND seq=$3`, environment, generation, sequence).Scan(&e.Environment, &e.Generation, &e.Sequence, &e.Host, &e.Cursor, &e.Repo, &e.URI, &e.Operation, &e.Revision, &e.CID, &e.Time, &e.Actor, &e.Subject, &e.Status, &e.Attempts, &e.RequiresVerification)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &e, err
}
func recommendationOrder(candidate, current recommendationEntry) RecordOrder {
	same := candidate.Operation == current.Operation && candidate.CID == current.CID && candidate.Subject == current.Subject
	if candidate.Revision.Valid && current.Revision.Valid && ValidRecordRevision(candidate.Revision.String) && ValidRecordRevision(current.Revision.String) {
		if candidate.Revision.String != current.Revision.String {
			if candidate.Revision.String > current.Revision.String {
				return RecordNewer
			}
			return RecordOlder
		}
		if same {
			return RecordSame
		}
		return RecordConflict
	}
	if candidate.Host == current.Host && candidate.Cursor == current.Cursor {
		if candidate.Sequence != current.Sequence {
			if candidate.Sequence > current.Sequence {
				return RecordNewer
			}
			return RecordOlder
		}
		if same && candidate.Revision == current.Revision {
			return RecordSame
		}
	}
	return RecordConflict
}
func (j *PostgresRecommendationJournal) reconcile(ctx context.Context, tx *sql.Tx, e recommendationEntry, at time.Time) (string, error) {
	var fenceGeneration string
	var fenceSequence int64
	err := tx.QueryRowContext(ctx, `SELECT source_generation,seq FROM wire_recommendation_record_fences WHERE environment=$1 AND source_uri=$2`, e.Environment, e.URI).Scan(&fenceGeneration, &fenceSequence)
	if err == sql.ErrNoRows {
		var newer bool
		if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_signal_events WHERE source_uri=$1 AND occurred_at>$2)`, e.URI, e.Time).Scan(&newer); err != nil {
			return "", err
		}
		if newer {
			return j.setStatus(ctx, tx, e, "superseded", "newer_existing_signal", at)
		}
	} else if err != nil {
		return "", err
	} else {
		previous, err := readRecommendation(ctx, tx, e.Environment, fenceGeneration, fenceSequence)
		if err != nil {
			return "", err
		}
		if previous != nil {
			switch recommendationOrder(e, *previous) {
			case RecordOlder:
				return j.setStatus(ctx, tx, e, "superseded", "newer_record_version", at)
			case RecordConflict:
				return j.setStatus(ctx, tx, e, "conflict", "incomparable_record_versions", at)
			case RecordSame:
				if e.Generation != previous.Generation || e.Sequence != previous.Sequence {
					return j.setStatus(ctx, tx, e, "superseded", "duplicate_record_version", at)
				}
			case RecordNewer:
				if _, err = j.setStatus(ctx, tx, *previous, "superseded", "newer_record_version", at); err != nil {
					return "", err
				}
			}
		}
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO wire_recommendation_record_fences(environment,source_uri,source_generation,seq,updated_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(environment,source_uri) DO UPDATE SET source_generation=EXCLUDED.source_generation,seq=EXCLUDED.seq,updated_at=EXCLUDED.updated_at WHERE(wire_recommendation_record_fences.source_generation,wire_recommendation_record_fences.seq)IS DISTINCT FROM(EXCLUDED.source_generation,EXCLUDED.seq)`, e.Environment, e.URI, e.Generation, e.Sequence, at); err != nil {
		return "", err
	}
	deleteSignals := func() error {
		_, err := tx.ExecContext(ctx, `DELETE FROM wire_signal_events WHERE source_uri=$1`, e.URI)
		return err
	}
	if e.Operation == "delete" {
		if err = deleteSignals(); err != nil {
			return "", err
		}
		return j.setStatus(ctx, tx, e, "deleted", "", at)
	}
	if !e.Time.Add(wirecore.SignalRetention).After(at) {
		if err = deleteSignals(); err != nil {
			return "", err
		}
		return j.setStatus(ctx, tx, e, "expired", "signal_retention_elapsed", at)
	}
	var active bool
	var cutoff sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT active,inactive_through FROM wire_recommendation_account_fences WHERE environment=$1 AND repo_did=$2`, e.Environment, e.Repo).Scan(&active, &cutoff)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	if err == nil {
		if cutoff.Valid && !e.Time.After(cutoff.Time) {
			return j.setStatus(ctx, tx, e, "superseded", "account_retracted", at)
		}
		if !active {
			return j.setStatus(ctx, tx, e, "pending", "account_inactive", at)
		}
	}
	if j.DependencyVerification {
		decision, reason, err := recommendationDependencyDecision(ctx, tx, e, at)
		if err != nil {
			return "", err
		}
		if decision == "pending" {
			return j.setStatus(ctx, tx, e, "pending", "dependency_verification_required", at)
		}
		if decision == "superseded" {
			return j.setStatus(ctx, tx, e, "superseded", reason, at)
		}
	}
	var canonical string
	err = tx.QueryRowContext(ctx, `SELECT canonical_key FROM wire_item_aliases WHERE alias_key=$1 AND expires_at>$2`, e.Subject, at).Scan(&canonical)
	if err == sql.ErrNoRows {
		if err = deleteSignals(); err != nil {
			return "", err
		}
		return j.setStatus(ctx, tx, e, "pending", "unresolved_subject", at)
	}
	if err != nil {
		return "", err
	}
	var exists bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_signal_events WHERE occurred_at=$1 AND source_uri=$2 AND transport_event_key=$3 AND canonical_key=$4)`, e.Time, e.URI, e.transportKey(), canonical).Scan(&exists); err != nil {
		return "", err
	}
	if !exists {
		var partition any
		if err = tx.QueryRowContext(ctx, `SELECT ensure_wire_signal_event_partition(($1::timestamptz AT TIME ZONE 'UTC')::date)`, e.Time).Scan(&partition); err != nil {
			return "", err
		}
		if err = deleteSignals(); err != nil {
			return "", err
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_signal_events(event_key,transport_event_key,canonical_key,signal_kind,actor_key_hash,source_uri,source_collection,source_action,occurred_at,expires_at) VALUES($1,$2,$3,'recommendation',$4,$5,'site.standard.graph.recommend','recommendation',$6,$7) ON CONFLICT DO NOTHING`, e.eventKey(), e.transportKey(), canonical, e.Actor, e.URI, e.Time, e.Time.Add(wirecore.SignalRetention)); err != nil {
			return "", err
		}
		var recorded bool
		if err = tx.QueryRowContext(ctx, `SELECT actor_recorded FROM wire_recommendation_journal WHERE environment=$1 AND source_generation=$2 AND seq=$3`, e.Environment, e.Generation, e.Sequence).Scan(&recorded); err != nil {
			return "", err
		}
		increment := 1
		if recorded {
			increment = 0
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_active_actors(actor_key_hash,first_active_at,last_active_at,public_signal_count,expires_at) VALUES($1,$2,$2,1,$3) ON CONFLICT(actor_key_hash) DO UPDATE SET last_active_at=GREATEST(wire_active_actors.last_active_at,EXCLUDED.last_active_at),public_signal_count=wire_active_actors.public_signal_count+$4,expires_at=GREATEST(wire_active_actors.expires_at,EXCLUDED.expires_at)`, e.Actor, at, at.Add(wirecore.ActiveActorRetention), increment); err != nil {
			return "", err
		}
	}
	if _, err = tx.ExecContext(ctx, `UPDATE wire_items SET provenance=provenance||'["recommendation"]'::jsonb,updated_at=$1 WHERE canonical_key=$2 AND NOT(provenance?'recommendation')`, at, canonical); err != nil {
		return "", err
	}
	return j.setStatus(ctx, tx, e, "resolved", "", at)
}
func recommendationDependencyDecision(ctx context.Context, tx *sql.Tx, e recommendationEntry, at time.Time) (string, string, error) {
	var status, generation string
	var sequence int64
	var expected, verified, subject, verifiedSubject, observed sql.NullString
	var until sql.NullTime
	err := tx.QueryRowContext(ctx, `SELECT status,source_generation,seq,expected_cid,verified_cid,subject_uri,verified_subject_uri,observed_repo_rev,valid_until FROM wire_recommendation_dependency_recovery WHERE environment=$1 AND source_uri=$2`, e.Environment, e.URI).Scan(&status, &generation, &sequence, &expected, &verified, &subject, &verifiedSubject, &observed, &until)
	if err != nil && err != sql.ErrNoRows {
		return "", "", err
	}
	if err == nil {
		if (status == "absent" || status == "changed") && e.CID == expected {
			exact := e.Generation == generation && e.Sequence == sequence
			older := e.Revision.Valid && observed.Valid && ValidRecordRevision(e.Revision.String) && ValidRecordRevision(observed.String) && e.Revision.String <= observed.String
			if exact || older {
				return "superseded", "authoritative_record_" + status, nil
			}
		}
		if status == "verified" && e.CID.Valid && e.CID == expected && e.CID == verified && e.Subject == subject && e.Subject == verifiedSubject && until.Valid && until.Time.After(at) {
			return "proceed", "", nil
		}
	}
	if e.Status == "pending" && e.RequiresVerification {
		return "pending", "", nil
	}
	return "proceed", "", nil
}
func (j *PostgresRecommendationJournal) setStatus(ctx context.Context, tx *sql.Tx, e recommendationEntry, status, reason string, at time.Time) (string, error) {
	delay := min(time.Duration(30*(1<<min(e.Attempts, 7)))*time.Second, time.Hour)
	if status != "pending" {
		delay = time.Hour
	}
	_, err := tx.ExecContext(ctx, `UPDATE wire_recommendation_journal SET status=$1,failure_reason=$2,updated_at=$3,actor_recorded=actor_recorded OR $4,dependency_verification_required=dependency_verification_required OR $5,attempt_count=attempt_count+1,next_attempt_at=$6 WHERE environment=$7 AND source_generation=$8 AND seq=$9`, status, stringPointer(reason), at, status == "resolved", status == "pending", at.Add(delay), e.Environment, e.Generation, e.Sequence)
	if err != nil {
		return "", err
	}
	if j.DependencyVerification && status == "pending" && e.Status == "resolved" {
		if _, err = tx.ExecContext(ctx, `UPDATE wire_recommendation_dependency_recovery SET next_attempt_at=$1,updated_at=$1 WHERE environment=$2 AND source_uri=$3 AND source_generation=$4 AND seq=$5 AND status NOT IN('absent','changed','unsupported')`, at, e.Environment, e.URI, e.Generation, e.Sequence); err != nil {
			return "", err
		}
	}
	if j.DependencyVerification && (status == "resolved" || status == "deleted" || status == "superseded" || status == "expired") {
		if _, err = tx.ExecContext(ctx, `UPDATE wire_recommendation_dependency_recovery SET next_attempt_at=$1,lease_token=NULL,lease_expires_at=NULL,updated_at=$2 WHERE environment=$3 AND source_uri=$4 AND source_generation=$5 AND seq=$6`, time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC), at, e.Environment, e.URI, e.Generation, e.Sequence); err != nil {
			return "", err
		}
	}
	return status, nil
}
