package thinappviewcore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"time"
)

var ErrStaleInboxLease = errors.New("stale AppView inbox lease")
var ErrInvalidInboxRow = errors.New("invalid AppView inbox row")

const IngestionScopePolicyVersion = "publication-author-viewer-v1"

var publicationAuthorCollections = []string{"site.standard.document", "site.standard.entry", "com.standard.document", "com.standard.entry"}
var viewerCollections = []string{"app.thesocialwire.finance.selection", "app.thesocialwire.sports.selection", "app.thesocialwire.readState", "app.skyreader.feed.subscription", "site.standard.graph.subscription"}

// InboxItem carries independent normalized metadata alongside the original envelope.
// LeaseToken fences every terminal transition against a replacement claimant.
type InboxItem struct {
	Environment, SourceGeneration                        string
	Sequence                                             int64
	SourceHost, EventKind, RepoDID                       string
	Collection, Operation, RepoRev, RecordKey, RecordCID *string
	Payload                                              []byte
	EventTime                                            time.Time
	AttemptCount                                         int
	LeaseToken                                           string
	LeaseExpiresAt                                       time.Time
}

type InboxStore struct{ DB *sql.DB }

func inboxLeaseToken() (string, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(token[:]), nil
}

func (s InboxStore) Claim(ctx context.Context, environment, generation, worker string, limit int, until, at time.Time) ([]InboxItem, error) {
	token, err := inboxLeaseToken()
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, inboxClaimSQL, environment, generation, at, publicationAuthorCollections, viewerCollections, max(1, limit), worker, token, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []InboxItem{}
	for rows.Next() {
		item := InboxItem{Environment: environment, SourceGeneration: generation, LeaseToken: token, LeaseExpiresAt: until}
		var payload string
		if err := rows.Scan(&item.Sequence, &item.SourceHost, &item.EventKind, &item.RepoDID, &item.Collection, &item.Operation, &item.RepoRev, &item.RecordKey, &item.RecordCID, &payload, &item.EventTime, &item.AttemptCount); err != nil {
			return nil, err
		}
		switch item.EventKind {
		case "commit", "identity", "account", "sync":
		default:
			return nil, ErrInvalidInboxRow
		}
		item.Payload = []byte(payload)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Sequence < items[j].Sequence })
	return items, nil
}

func (s InboxStore) FilterOutsideScope(ctx context.Context, environment, generation string, limit int, expires, at time.Time) (int, error) {
	managed := append(append([]string{}, publicationAuthorCollections...), viewerCollections...)
	rows, err := s.DB.QueryContext(ctx, inboxFilterSQL, environment, generation, at, managed, publicationAuthorCollections, viewerCollections, max(1, min(limit, 10000)), IngestionScopePolicyVersion, expires)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		count++
	}
	return count, rows.Err()
}

func (s InboxStore) Applied(ctx context.Context, item InboxItem, worker string, expires, at time.Time) error {
	return inboxTransition(ctx, s.DB, inboxAppliedSQL, at, expires, item.Environment, item.SourceGeneration, item.Sequence, worker, item.LeaseToken)
}
func (s InboxStore) Retry(ctx context.Context, item InboxItem, worker, category, reason string, next, at time.Time) error {
	return inboxTransition(ctx, s.DB, inboxRetrySQL, next, category, truncateInboxReason(reason), at, item.Environment, item.SourceGeneration, item.Sequence, worker, item.LeaseToken)
}
func (s InboxStore) Renew(ctx context.Context, item InboxItem, worker string, until, at time.Time) error {
	return inboxTransition(ctx, s.DB, inboxRenewSQL, until, at, item.Environment, item.SourceGeneration, item.Sequence, worker, item.LeaseToken)
}
func (s InboxStore) AdvanceAppliedWatermark(ctx context.Context, environment, generation string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, inboxWatermarkSQL, environment, generation, at)
	return err
}

func truncateInboxReason(reason string) string {
	r := []rune(reason)
	if len(r) > 1000 {
		return string(r[:1000])
	}
	return reason
}

type inboxQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func inboxTransition(ctx context.Context, q inboxQueryer, statement string, args ...any) error {
	var changed int
	err := q.QueryRowContext(ctx, statement, args...).Scan(&changed)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStaleInboxLease
	}
	return err
}

// DeadLetter and its repository reconciliation request commit together; a stale
// claimant cannot create recovery work for a replacement owner's event.
func (s InboxStore) DeadLetter(ctx context.Context, item InboxItem, worker, category, reason string, expires, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := inboxTransition(ctx, tx, inboxDeadLetterSQL, at, category, truncateInboxReason(reason), expires, item.Environment, item.SourceGeneration, item.Sequence, worker, item.LeaseToken); err != nil {
		return err
	}
	requestID := fmt.Sprintf("%s:%d:%s", item.SourceGeneration, item.Sequence, item.RepoDID)
	if _, err := tx.ExecContext(ctx, inboxScheduleReconciliationSQL, item.Environment, requestID, item.SourceGeneration, item.RepoDID, category, item.Sequence, at); err != nil {
		return err
	}
	return tx.Commit()
}

func (s InboxStore) ResolveRecoveredIncidents(ctx context.Context, environment, generation string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, inboxResolveRecoveredSQL, at, environment, generation)
	return err
}
func (s InboxStore) ResolveRetiredIncidents(ctx context.Context, environment, generation, leaseName string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, inboxResolveRetiredSQL, leaseName, at, environment, generation)
	return err
}
