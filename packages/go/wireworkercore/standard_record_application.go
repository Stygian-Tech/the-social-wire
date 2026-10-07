package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// StandardRecordApplication owns the atomic projection/fence/ack path. Expensive
// publication/blob lookups happen before reserving the transaction connection.
type StandardRecordApplication struct {
	DB           *sql.DB
	Hasher       *wirecore.ActorHasher
	Publications PublicationResolver
	Blobs        BlobResolver
}

func parseStandardRecord(event InboxEvent) (map[string]any, error) {
	if event.Collection.String != "site.standard.document" && event.Collection.String != "site.standard.entry" && event.Collection.String != "site.standard.publication" || !event.RecordKey.Valid || event.RecordKey.String == "" || strings.Contains(event.RecordKey.String, "/") {
		return nil, ErrMalformedDocument
	}
	var document map[string]any
	if err := json.Unmarshal([]byte(event.PayloadJSON), &document); err != nil {
		return nil, ErrMalformedDocument
	}
	if failure, ok := document["$wireIngestionError"].(map[string]any); ok && failure["code"] == "payload_normalization_failed" {
		return nil, ErrMalformedDocument
	}
	if event.EventKind == "snapshot" || event.CursorKind == "pds_record_snapshot" {
		if event.EventKind != "snapshot" || event.CursorKind != "pds_record_snapshot" || event.Operation.String != "update" {
			return nil, ErrMalformedDocument
		}
		snapshot, ok := document["snapshot"].(map[string]any)
		if !ok || recordString(snapshot, "cid") == "" || !ValidRecordRevision(recordString(snapshot, "rev")) {
			return nil, ErrMalformedDocument
		}
		record, ok := snapshot["record"].(map[string]any)
		if !ok || record["$type"] != event.Collection.String {
			return nil, ErrMalformedDocument
		}
		return record, nil
	}
	if event.EventKind != "commit" || event.Operation.String != "create" && event.Operation.String != "update" && event.Operation.String != "delete" {
		return nil, ErrMalformedDocument
	}
	if event.Operation.String == "delete" {
		return nil, nil
	}
	commit, ok := document["commit"].(map[string]any)
	if !ok {
		return nil, ErrMalformedDocument
	}
	record, ok := commit["record"].(map[string]any)
	if !ok {
		return nil, ErrMalformedDocument
	}
	if kind, exists := record["$type"]; exists && kind != event.Collection.String {
		return nil, ErrMalformedDocument
	}
	return record, nil
}

type inboxQuerier interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func standardLease(ctx context.Context, query inboxQuerier, event InboxEvent, at time.Time, locked bool) (sql.NullString, sql.NullString, bool, error) {
	sqlText := `SELECT repo_rev,record_cid,payload=$1::jsonb AND event_kind=$2 AND cursor_kind=$3 AND operation=$4 AND collection=$5 AND repo_did=$6 AND record_key=$7 AND source_host=$8 AND event_time=$9 AND(event_kind<>'snapshot' OR(record_cid IS NOT NULL AND repo_rev IS NOT NULL AND record_cid=payload#>>'{snapshot,cid}' AND repo_rev=payload#>>'{snapshot,rev}')) FROM wire_ingestion_inbox WHERE environment=$10 AND source_generation=$11 AND seq=$12 AND status='leased' AND lease_token=$13 AND lease_expires_at>$14`
	if locked {
		sqlText += " FOR UPDATE"
	}
	var revision, cid sql.NullString
	var valid sql.NullBool
	err := query.QueryRowContext(ctx, sqlText, event.PayloadJSON, event.EventKind, event.CursorKind, event.Operation, event.Collection, event.Repository.RepoDID, event.RecordKey, event.SourceHost, event.EventTime, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.LeaseToken, at).Scan(&revision, &cid, &valid)
	if err == sql.ErrNoRows {
		return revision, cid, false, nil
	}
	if err != nil {
		return revision, cid, false, err
	}
	if !valid.Valid || !valid.Bool {
		return revision, cid, false, ErrMalformedDocument
	}
	return revision, cid, true, nil
}
func (a StandardRecordApplication) Apply(ctx context.Context, event InboxEvent, at time.Time) (outcome InboxOutcome, applicationError error) {
	record, err := parseStandardRecord(event)
	if err != nil {
		return "", err
	}
	revision, cid, claimed, err := standardLease(ctx, a.DB, event, at, false)
	if err != nil {
		return "", err
	}
	if !claimed {
		return InboxLeaseLost, nil
	}
	tx, err := a.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return "", err
	}
	previous, err := LoadStandardRecordFence(ctx, tx, event)
	rollbackErr := tx.Rollback()
	if err != nil {
		return "", err
	}
	if rollbackErr != nil {
		return "", rollbackErr
	}
	candidate := NewStandardRecordFence(event, revision, cid)
	preflight := RecordNewer
	if previous != nil {
		preflight = candidate.Compare(*previous)
	}
	var resolved *ResolvedDocument
	var thumbnail *string
	if event.Collection.String != "site.standard.publication" && preflight != RecordOlder && preflight != RecordConflict && record != nil {
		resolved, err = ResolveDocument(ctx, record, a.Publications, at)
		if errors.Is(err, ErrUnaddressableDocument) {
			err = nil
		}
		if err != nil {
			return "", err
		}
		thumbnail, err = resolveRecordImage(ctx, record, event.Repository.RepoDID, a.Blobs)
		if err != nil {
			return "", err
		}
	}
	publicationURI := ""
	if event.Collection.String == "site.standard.publication" {
		publicationURI = event.SourceURI()
		if a.Publications != nil {
			a.Publications.Invalidate(publicationURI)
			defer a.Publications.Invalidate(publicationURI)
		}
	}
	tx, err = a.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer func() {
		if rollbackError := tx.Rollback(); rollbackError != nil && rollbackError != sql.ErrTxDone {
			applicationError = fmt.Errorf("standard record rollback uncertain: %w", rollbackError)
		}
	}()
	revision, cid, claimed, err = standardLease(ctx, tx, event, at, true)
	if err != nil {
		return "", err
	}
	if !claimed {
		return InboxLeaseLost, nil
	}
	accountLock := "wire-recommendation-account:" + event.Repository.Environment + ":" + event.Repository.RepoDID
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, accountLock); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, event.SourceURI()); err != nil {
		return "", err
	}
	candidate = NewStandardRecordFence(event, revision, cid)
	previous, err = LoadStandardRecordFence(ctx, tx, event)
	if err != nil {
		return "", err
	}
	order := RecordNewer
	if previous != nil {
		order = candidate.Compare(*previous)
	}
	complete := func(status, reason string, retry time.Time, outcome InboxOutcome) (InboxOutcome, error) {
		accepted, e := FinishInbox(ctx, tx, event, status, retry, stringPointer(reason), at)
		if e != nil {
			return "", e
		}
		if !accepted {
			return InboxLeaseLost, nil
		}
		if e = tx.Commit(); e != nil {
			return "", e
		}
		return outcome, nil
	}
	if order == RecordOlder {
		return complete("dead_letter", "standard_record_superseded", at, InboxTerminal)
	}
	if order == RecordConflict {
		return complete("retry", "standard_record_order_conflict", at.Add(300*time.Second), InboxRetry)
	}
	if event.Collection.String != "site.standard.publication" && event.Operation.String != "delete" && (preflight == RecordOlder || preflight == RecordConflict) {
		return complete("retry", "standard_record_resolve_again", at.Add(time.Second), InboxRetry)
	}
	effectiveTime := event.EventTime
	if order == RecordSame && previous != nil && previous.Time.Before(effectiveTime) {
		effectiveTime = previous.Time
	}
	var active bool
	var inactiveThrough sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT active,inactive_through FROM wire_recommendation_account_fences WHERE environment=$1 AND repo_did=$2`, event.Repository.Environment, event.Repository.RepoDID).Scan(&active, &inactiveThrough)
	if err != nil && err != sql.ErrNoRows {
		return "", err
	}
	if err == nil && event.Operation.String != "delete" && (!active || inactiveThrough.Valid && !effectiveTime.After(inactiveThrough.Time)) {
		reason := "standard_record_account_inactive"
		if event.EventKind == "snapshot" {
			reason = "snapshot_account_inactive"
		}
		return complete("dead_letter", reason, at, InboxTerminal)
	}
	if err = ctx.Err(); err != nil {
		return "", err
	}
	record, err = parseStandardRecord(event)
	if err != nil {
		return "", err
	}
	snapshot := event.EventKind == "snapshot"
	hadActivity := order == RecordSame && previous != nil && previous.ActivityRecorded
	activityEvent := event
	if hadActivity {
		activityEvent.Repository.SourceGeneration = previous.Generation
		activityEvent.Sequence = previous.Sequence
		activityEvent.SourceHost = previous.Host
		activityEvent.CursorKind = previous.Cursor
		activityEvent.EventKind = previous.Kind
		activityEvent.Operation = nullString(previous.Operation)
		activityEvent.EventTime = previous.Time
	}
	if event.Operation.String == "delete" {
		if event.Collection.String == "site.standard.publication" {
			_, err = tx.ExecContext(ctx, `DELETE FROM wire_publications WHERE publication_uri=$1`, event.SourceURI())
		} else {
			for _, query := range []string{`DELETE FROM wire_signal_events WHERE source_uri=$1`, `DELETE FROM wire_item_aliases WHERE alias_key=$1`} {
				if _, err = tx.ExecContext(ctx, query, event.SourceURI()); err != nil {
					return "", err
				}
			}
			_, err = tx.ExecContext(ctx, `UPDATE wire_items SET updated_at=$2 WHERE representative_uri=$1`, event.SourceURI(), at)
		}
	} else if event.Collection.String == "site.standard.publication" && record != nil {
		metadata := ParsePublicationMetadata(event.SourceURI(), event.Repository.RepoDID, record)
		if metadata == nil {
			return "", ErrMalformedDocument
		}
		err = SavePublicationMetadata(ctx, tx, *metadata, event.EventTime, true)
	} else if resolved != nil && record != nil {
		var signalTime *time.Time
		if order == RecordSame && previous != nil && previous.Kind == "snapshot" {
			signalTime = &event.EventTime
		}
		err = a.applyArticle(ctx, tx, record, activityEvent, *resolved, thumbnail, at, !snapshot, !hadActivity, !snapshot && !hadActivity, signalTime)
	}
	if err != nil {
		return "", err
	}
	recordsActivity := !snapshot && event.Operation.String != "delete" && event.Collection.String != "site.standard.publication" && resolved != nil
	fence := candidate
	if order == RecordSame && previous != nil && (previous.ActivityRecorded || !recordsActivity) {
		fence = *previous
		if snapshot {
			fence = fence.Observing(revision)
		}
	} else {
		fence.ActivityRecorded = recordsActivity
		if order == RecordSame && previous != nil {
			fence = fence.Observing(previous.ObservedRevision)
		}
	}
	if err = fence.Save(ctx, tx, event, at); err != nil {
		return "", err
	}
	return complete("applied", "", at, InboxApplied)
}
func (a StandardRecordApplication) applyArticle(ctx context.Context, tx *sql.Tx, record map[string]any, event InboxEvent, resolved ResolvedDocument, thumbnail *string, at time.Time, recordsActivity, incrementsActivity, refreshesSignal bool, signalTime *time.Time) error {
	identity := wirecore.Canonicalize(resolved.CanonicalURL)
	if identity == nil {
		return ErrMalformedDocument
	}
	u, _ := url.Parse(identity.CanonicalURL)
	kind := wirecore.TargetKindForURL(identity.CanonicalURL, true)
	if !kind.CanCreateItem() {
		return nil
	}
	host := u.Hostname()
	title := recordString(record, "title", "name")
	if title == "" {
		title = host
	}
	language := strings.ToLower(recordString(record, "lang", "language"))
	language = strings.Split(language, "-")[0]
	if len([]rune(language)) < 2 || len([]rune(language)) > 8 {
		language = "und"
	}
	var published *time.Time
	if t, e := time.Parse(time.RFC3339Nano, recordString(record, "publishedAt", "createdAt")); e == nil {
		published = &t
	}
	topics := []string{}
	if tags, ok := record["tags"].([]any); ok {
		allStrings := true
		for _, tag := range tags {
			value, ok := tag.(string)
			if !ok {
				allStrings = false
				break
			}
			topics = append(topics, strings.ToLower(value))
		}
		if !allStrings {
			topics = []string{}
		}
	}
	name := host
	if resolved.PublicationName != nil {
		name = *resolved.PublicationName
	} else if value := recordString(record, "publicationName", "siteName"); value != "" {
		name = value
	}
	homepage := resolved.PublicationHomepageURL
	if homepage == nil {
		homepage = stringPointer("https://" + u.Host)
	}
	item := ItemProjection{Identity: *identity, RepresentativeURI: event.SourceURI(), AuthorDID: stringPointer(event.Repository.RepoDID), Host: host, SourceName: name, Title: title, Language: language, PresentationSource: "standard_site", PresentationPriority: 400, InspectionURL: resolved.CanonicalURL, PublicationID: resolved.PublicationURI, AuthorName: stringPointer(recordString(record, "authorName", "displayName", "byline", "author")), Topics: topics, Summary: stringPointer(recordString(record, "summary", "description", "text", "textContent")), Thumbnail: thumbnail, HomepageURL: homepage, PublishedAt: published, Provenance: []string{"standard_site"}, Confidence: .9, TargetKind: kind, RecordsActivity: refreshesSignal, SignalTime: signalTime}
	if err := UpsertProjectedItem(ctx, tx, item, at); err != nil {
		return err
	}
	if err := UpsertItemAlias(ctx, tx, event.SourceURI(), "at_uri", identity.CanonicalKey, at); err != nil {
		return err
	}
	if err := UpsertItemAlias(ctx, tx, identity.CanonicalURL, "url", identity.CanonicalKey, at); err != nil {
		return err
	}
	if !recordsActivity || !(incrementsActivity && signalTime == nil || event.EventTime.Add(wirecore.SignalRetention).After(at)) {
		return nil
	}
	if a.Hasher == nil {
		return fmt.Errorf("actor hasher required")
	}
	actor, err := a.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	actorAt := event.EventTime
	if incrementsActivity {
		actorAt = at
		if signalTime != nil {
			actorAt = *signalTime
		}
	}
	if err = UpsertActiveActor(ctx, tx, actor, actorAt, incrementsActivity); err != nil {
		return err
	}
	if !event.EventTime.Add(wirecore.SignalRetention).After(at) {
		return nil
	}
	return InsertProjectedSignal(ctx, tx, event, identity.CanonicalKey, actor, event.SourceURI(), "publication")
}
func resolveRecordImage(ctx context.Context, record map[string]any, repo string, blobs BlobResolver) (*string, error) {
	for _, key := range []string{"coverImage", "thumbnail", "thumbnailUrl", "coverImageUrl", "image", "heroImage", "socialImage"} {
		if raw, ok := record[key].(string); ok {
			u, err := url.Parse(strings.TrimSpace(raw))
			if err == nil && u.User == nil && (strings.ToLower(u.Scheme) == "https" || strings.ToLower(u.Scheme) == "http") {
				u.Scheme = "https"
				u.Host = strings.ToLower(u.Host)
				if thinappviewcore.ValidatePDSBase("https://"+u.Host) != "" {
					normalized := u.String()
					return &normalized, nil
				}
			}
		}
	}
	if blobs == nil {
		return nil, nil
	}
	for _, key := range []string{"coverImage", "thumbnail"} {
		object, ok := record[key].(map[string]any)
		if !ok {
			continue
		}
		cid := recordString(object, "$link")
		if ref, ok := object["ref"].(map[string]any); ok && cid == "" {
			cid = recordString(ref, "$link")
		}
		if cid == "" || len([]rune(cid)) > 512 {
			continue
		}
		value, err := blobs.ResolveBlobURL(ctx, repo, cid)
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if err == nil {
			return stringPointer(value), nil
		}
		return nil, nil
	}
	return nil, nil
}
