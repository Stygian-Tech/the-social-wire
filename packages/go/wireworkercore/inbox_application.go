package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

var ErrUnresolvedSubject = errors.New("unresolved subject")

type RecommendationProcessor interface {
	Process(context.Context, InboxEvent, *wirecore.ActorHasher, time.Time, bool) (InboxOutcome, error)
}
type ExternalSignalProjector interface {
	Apply(context.Context, *sql.Tx, map[string]any, InboxEvent, time.Time) error
}
type PostgresInboxProcessor struct {
	PostgresInboxClaims
	Hasher                  *wirecore.ActorHasher
	Standard                StandardRecordApplication
	Recommendations         RecommendationProcessor
	External                ExternalSignalProjector
	DeferredRecommendations bool
}

func (p *PostgresInboxProcessor) ApplyClaimed(ctx context.Context, event InboxEvent, at time.Time) (InboxOutcome, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if event.EventKind == "account" && p.Standard.Publications != nil {
		var accountDocument map[string]any
		if json.Unmarshal([]byte(event.PayloadJSON), &accountDocument) == nil {
			if active, ok := object(accountDocument["account"])["active"].(bool); ok && !active {
				p.Standard.Publications.InvalidateAccount(event.Repository.RepoDID)
				defer p.Standard.Publications.InvalidateAccount(event.Repository.RepoDID)
			}
		}
	}
	var outcome InboxOutcome
	var err error
	if event.EventKind == "snapshot" || event.CursorKind == "pds_record_snapshot" || event.EventKind == "commit" && (event.Collection.String == "site.standard.document" || event.Collection.String == "site.standard.entry" || event.Collection.String == "site.standard.publication") {
		outcome, err = p.Standard.Apply(ctx, event, at)
	} else if event.EventKind == "commit" && event.Collection.String == "site.standard.graph.recommend" {
		if p.Recommendations == nil {
			return "", errors.New("recommendation journal is required")
		}
		outcome, err = p.Recommendations.Process(ctx, event, p.Hasher, at, p.DeferredRecommendations)
	} else {
		outcome, err = p.applyNormal(ctx, event, at)
	}
	if err == nil {
		return outcome, nil
	}
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	status, reason, retry, result := "retry", err.Error(), at.Add(60*time.Second), InboxRetry
	switch {
	case errors.Is(err, ErrMalformedDocument):
		status = "dead_letter"
		reason = "malformed_event"
		retry = at
		result = InboxTerminal
	case errors.Is(err, ErrUnresolvedSubject):
		if at.Sub(event.EventTime) < 24*time.Hour {
			reason = "unresolved_subject"
			retry = at.Add(30 * time.Second)
		} else {
			status = "dead_letter"
			reason = "unresolved_subject_expired"
			retry = at
			result = InboxTerminal
		}
	case errors.Is(err, ErrUnresolvedPublication):
		if at.Sub(event.EventTime) < 24*time.Hour {
			reason = "unresolved_publication"
			retry = at.Add(publicationRetry(event.AttemptCount))
		} else {
			status = "dead_letter"
			reason = "unresolved_publication_expired"
			retry = at
			result = InboxTerminal
		}
	default:
		if event.AttemptCount >= 8 {
			status = "dead_letter"
			retry = at
			result = InboxTerminal
		}
		if len([]rune(reason)) > 500 {
			reason = string([]rune(reason)[:500])
		}
	}
	tx, e := p.DB.BeginTx(ctx, nil)
	if e != nil {
		return "", e
	}
	defer tx.Rollback()
	accepted, e := FinishInbox(ctx, tx, event, status, retry, &reason, at)
	if e != nil {
		return "", e
	}
	if !accepted {
		return InboxLeaseLost, nil
	}
	if e = tx.Commit(); e != nil {
		return "", e
	}
	return result, nil
}
func publicationRetry(attempt int) time.Duration {
	exponent := max(0, min(attempt-1, 4))
	return min(time.Duration(300*(1<<exponent))*time.Second, time.Hour)
}
func (p *PostgresInboxProcessor) applyNormal(ctx context.Context, event InboxEvent, at time.Time) (outcome InboxOutcome, applicationError error) {
	var document map[string]any
	if err := json.Unmarshal([]byte(event.PayloadJSON), &document); err != nil {
		return "", ErrMalformedDocument
	}
	if failure := object(document["$wireIngestionError"]); failure["code"] == "payload_normalization_failed" {
		return "", ErrMalformedDocument
	}
	// Missing required adapters are configuration errors and must not claim success.
	if supportedExternalCollection(event.Collection.String) && p.External == nil {
		return "", errors.New("external signal projector is required")
	}
	tx, err := p.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer func() {
		if e := tx.Rollback(); e != nil && e != sql.ErrTxDone {
			applicationError = fmt.Errorf("Wire projection rollback uncertain: %w", e)
		}
	}()
	var valid bool
	err = tx.QueryRowContext(ctx, `SELECT TRUE FROM wire_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq=$3 AND status='leased' AND lease_token=$4 AND lease_expires_at>$5 FOR UPDATE`, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.LeaseToken, at).Scan(&valid)
	if err == sql.ErrNoRows {
		return InboxLeaseLost, nil
	}
	if err != nil {
		return "", err
	}
	if event.EventKind == "account" {
		err = p.applyAccount(ctx, tx, event, document, at)
	} else if event.EventKind == "commit" && event.Collection.Valid && event.Operation.Valid && event.SourceURI() != "" {
		if event.Operation.String == "delete" {
			err = RetractSource(ctx, tx, event.SourceURI(), event.EventTime, at)
		} else {
			if event.Operation.String != "create" && event.Operation.String != "update" {
				return "", ErrMalformedDocument
			}
			record := object(object(document["commit"])["record"])
			if record == nil {
				return "", ErrMalformedDocument
			}
			switch event.Collection.String {
			case "app.bsky.feed.post":
				err = ApplyPostProjection(ctx, tx, p.Hasher, record, event, at)
			case "app.bsky.feed.like":
				err = p.applyReference(ctx, tx, record, event, "like", at)
			case "app.bsky.feed.repost":
				err = p.applyReference(ctx, tx, record, event, "repost", at)
			case "app.thesocialwire.wireFeedback":
				err = p.applyFeedback(ctx, tx, record, event, at)
			case "app.bsky.graph.follow":
				err = p.applyFollow(ctx, tx, record, event, at)
			default:
				if supportedExternalCollection(event.Collection.String) {
					err = p.External.Apply(ctx, tx, record, event, at)
				}
			}
		}
	}
	if err != nil {
		return "", err
	}
	accepted, err := FinishInbox(ctx, tx, event, "applied", at, nil, at)
	if err != nil {
		return "", err
	}
	if !accepted {
		return InboxLeaseLost, nil
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return InboxApplied, nil
}
func supportedExternalCollection(value string) bool {
	switch value {
	case "at.margin.note", "at.margin.reply", "at.margin.like", "at.margin.collectionItem", "at.margin.readingRoom", "network.cosmik.card", "network.cosmik.connection", "network.cosmik.collectionLink", "network.cosmik.collectionLinkRemoval":
		return true
	}
	return false
}
func appendItemProvenance(ctx context.Context, tx *sql.Tx, key, kind string, at time.Time) error {
	_, err := tx.ExecContext(ctx, `UPDATE wire_items item SET provenance=(SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb) FROM(SELECT DISTINCT value FROM jsonb_array_elements_text(item.provenance||to_jsonb(ARRAY[$1]::text[])))unique_provenance),updated_at=$2 WHERE canonical_key=$3 AND NOT(item.provenance?$1)`, kind, at, key)
	return err
}
func aliasCanonicalKey(ctx context.Context, tx *sql.Tx, alias string) (string, error) {
	var key string
	err := tx.QueryRowContext(ctx, `SELECT canonical_key FROM wire_item_aliases WHERE alias_key=$1 AND expires_at>NOW() LIMIT 1`, alias).Scan(&key)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return key, err
}
func (p *PostgresInboxProcessor) applyReference(ctx context.Context, tx *sql.Tx, record map[string]any, event InboxEvent, kind string, at time.Time) error {
	var subject string
	if value, ok := record["subject"].(string); ok {
		subject = value
	} else {
		subject = recordString(object(record["subject"]), "uri")
	}
	if subject == "" {
		return ErrMalformedDocument
	}
	key, err := aliasCanonicalKey(ctx, tx, subject)
	if err != nil {
		return err
	}
	if key == "" {
		return nil
	}
	actor, err := p.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	if err = UpsertActiveActor(ctx, tx, actor, at, true); err != nil {
		return err
	}
	if err = appendItemProvenance(ctx, tx, key, kind, at); err != nil {
		return err
	}
	return InsertProjectedSignal(ctx, tx, event, key, actor, event.SourceURI(), kind)
}
func (p *PostgresInboxProcessor) applyFeedback(ctx context.Context, tx *sql.Tx, record map[string]any, event InboxEvent, at time.Time) error {
	identity := wirecore.Canonicalize(recordString(record, "canonicalUrl"))
	value := recordString(record, "value")
	if identity == nil || value != "good" && value != "not_good" {
		return ErrMalformedDocument
	}
	var exists bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_items WHERE canonical_key=$1 AND expires_at>NOW())`, identity.CanonicalKey).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrUnresolvedSubject
	}
	actor, err := p.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	if err = UpsertActiveActor(ctx, tx, actor, at, true); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, event.SourceURI()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_article_feedback WHERE source_uri=$1 AND occurred_at<=$2`, event.SourceURI(), event.EventTime); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO wire_article_feedback(canonical_key,actor_key_hash,source_uri,feedback_value,occurred_at,expires_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(canonical_key,actor_key_hash) DO UPDATE SET source_uri=EXCLUDED.source_uri,feedback_value=EXCLUDED.feedback_value,occurred_at=EXCLUDED.occurred_at,expires_at=EXCLUDED.expires_at WHERE wire_article_feedback.occurred_at<=EXCLUDED.occurred_at`, identity.CanonicalKey, actor, event.SourceURI(), value, event.EventTime, event.EventTime.Add(wirecore.SignalRetention))
	return err
}
func (p *PostgresInboxProcessor) applyFollow(ctx context.Context, tx *sql.Tx, record map[string]any, event InboxEvent, at time.Time) error {
	subject, ok := record["subject"].(string)
	if !ok {
		return ErrMalformedDocument
	}
	follower, err := p.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	followee, err := p.Hasher.Hash(subject)
	if err != nil {
		return err
	}
	if follower == followee {
		_, err = tx.ExecContext(ctx, `DELETE FROM wire_follow_edges WHERE source_uri=$1`, event.SourceURI())
		return err
	}
	var active bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_active_actors WHERE actor_key_hash=$1 AND expires_at>$2)`, follower, at).Scan(&active); err != nil {
		return err
	}
	if !active {
		return nil
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_follow_edges WHERE source_uri=$1`, event.SourceURI()); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO wire_follow_edges(source_uri,follower_key_hash,followee_key_hash,observed_at,expires_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(follower_key_hash,followee_key_hash) DO UPDATE SET source_uri=EXCLUDED.source_uri,observed_at=EXCLUDED.observed_at,expires_at=EXCLUDED.expires_at`, event.SourceURI(), follower, followee, at, at.Add(wirecore.FollowEdgeRetention)); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `DELETE FROM wire_follow_edges edge WHERE edge.follower_key_hash=$1 AND edge.followee_key_hash IN(SELECT followee_key_hash FROM wire_follow_edges WHERE follower_key_hash=$1 ORDER BY observed_at DESC,followee_key_hash OFFSET $2)`, follower, wirecore.MaximumFollowEdgesPerActor)
	return err
}
func (p *PostgresInboxProcessor) applyAccount(ctx context.Context, tx *sql.Tx, event InboxEvent, document map[string]any, at time.Time) error {
	account := object(document["account"])
	active, ok := account["active"].(bool)
	if !ok {
		return nil
	}
	actor, err := p.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "wire-recommendation-account:"+event.Repository.Environment+":"+event.Repository.RepoDID); err != nil {
		return err
	}
	var inactive *time.Time
	if !active {
		inactive = &event.EventTime
	}
	var accepted bool
	err = tx.QueryRowContext(ctx, `INSERT INTO wire_recommendation_account_fences(environment,repo_did,active,event_time,inactive_through,updated_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(environment,repo_did) DO UPDATE SET active=CASE WHEN EXCLUDED.event_time>wire_recommendation_account_fences.event_time OR(EXCLUDED.event_time=wire_recommendation_account_fences.event_time AND NOT EXCLUDED.active) THEN EXCLUDED.active ELSE wire_recommendation_account_fences.active END,event_time=GREATEST(wire_recommendation_account_fences.event_time,EXCLUDED.event_time),inactive_through=GREATEST(wire_recommendation_account_fences.inactive_through,EXCLUDED.inactive_through),updated_at=EXCLUDED.updated_at RETURNING event_time=$4 AND active=$3`, event.Repository.Environment, event.Repository.RepoDID, active, event.EventTime, inactive, at).Scan(&accepted)
	if err != nil {
		return err
	}
	if !accepted || active {
		return nil
	}
	if _, err = tx.ExecContext(ctx, `UPDATE wire_items SET eligible=FALSE,updated_at=$2 WHERE author_key=$1`, event.Repository.RepoDID, at); err != nil {
		return err
	}
	for _, query := range []string{`DELETE FROM wire_signal_events WHERE actor_key_hash=$1`, `DELETE FROM wire_follow_edges WHERE follower_key_hash=$1 OR followee_key_hash=$1`, `DELETE FROM wire_active_actors WHERE actor_key_hash=$1`, `DELETE FROM wire_article_feedback WHERE actor_key_hash=$1`} {
		if _, err = tx.ExecContext(ctx, query, actor); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_publications WHERE repo_did=$1`, event.Repository.RepoDID); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_item_mentions WHERE subject_did=$1 OR speaker_key_hash=$2`, event.Repository.RepoDID, actor); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `DELETE FROM wire_talked_accounts WHERE subject_did=$1`, event.Repository.RepoDID)
	return err
}

func NormalizationFailure(payload string) bool {
	var document map[string]any
	return json.Unmarshal([]byte(payload), &document) == nil && object(document["$wireIngestionError"])["code"] == "payload_normalization_failed"
}
