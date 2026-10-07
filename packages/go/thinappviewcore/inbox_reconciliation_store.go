package thinappviewcore

import (
	"context"
	"errors"
	"sort"
	"time"
)

type ReconciliationRequest struct {
	Environment, SourceGeneration, ID, RepoDID, Reason string
	TriggerSequence                                    int64
	AttemptCount                                       int
	LeaseToken                                         string
	LeaseExpiresAt                                     time.Time
}

func (s InboxStore) ClaimReconciliations(ctx context.Context, environment, generation, worker string, limit int, until, at time.Time) ([]ReconciliationRequest, error) {
	token, err := inboxLeaseToken()
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, inboxReconciliationClaim0SQL, environment, generation, at, max(1, limit), worker, token, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	requests := []ReconciliationRequest{}
	for rows.Next() {
		request := ReconciliationRequest{Environment: environment, SourceGeneration: generation, LeaseToken: token, LeaseExpiresAt: until}
		if err := rows.Scan(&request.ID, &request.RepoDID, &request.Reason, &request.TriggerSequence, &request.AttemptCount); err != nil {
			return nil, err
		}
		requests = append(requests, request)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(requests, func(i, j int) bool {
		if requests[i].TriggerSequence == requests[j].TriggerSequence {
			return requests[i].ID < requests[j].ID
		}
		return requests[i].TriggerSequence < requests[j].TriggerSequence
	})
	return requests, nil
}
func (s InboxStore) RenewReconciliation(ctx context.Context, request ReconciliationRequest, worker string, until, at time.Time) error {
	return inboxTransition(ctx, s.DB, inboxReconciliationRenew0SQL, until, at, request.Environment, request.ID, worker, request.LeaseToken)
}
func (s InboxStore) RetryReconciliation(ctx context.Context, request ReconciliationRequest, worker, reason string, next, at time.Time) error {
	r := []rune(reason)
	if len(r) > 512 {
		reason = string(r[:512])
	}
	return inboxTransition(ctx, s.DB, inboxReconciliationRetry0SQL, next, reason, at, request.Environment, request.ID, worker, request.LeaseToken)
}
func (s InboxStore) CompleteReconciliation(ctx context.Context, request ReconciliationRequest, worker string, expires, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := inboxTransition(ctx, tx, inboxReconciliationComplete0SQL, at, request.Environment, request.ID, worker, request.LeaseToken); err != nil {
		return err
	}
	err = inboxTransition(ctx, tx, inboxReconciliationComplete1SQL, at, expires, request.Environment, request.SourceGeneration, request.TriggerSequence, request.RepoDID)
	if errors.Is(err, ErrStaleInboxLease) {
		return ErrInvalidInboxRow
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, inboxReconciliationComplete2SQL, at, request.Environment, request.SourceGeneration, request.TriggerSequence); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, inboxWatermarkSQL, request.Environment, request.SourceGeneration, at); err != nil {
		return err
	}
	return tx.Commit()
}

// Reconciled records a successful sync while retaining the inbox claim until its
// separate Applied acknowledgement. All checkpoint and recovery updates are atomic.
func (s InboxStore) Reconciled(ctx context.Context, item InboxItem, worker, repoRev string, expires, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := inboxTransition(ctx, tx, inboxReconciled0SQL, at, expires, item.Environment, item.SourceGeneration, item.Sequence, item.RepoDID, worker, item.LeaseToken); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, inboxReconciled1SQL, repoRev, at, item.Environment, item.SourceGeneration); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, inboxReconciled2SQL, at, item.Environment, item.SourceGeneration, item.RepoDID, item.Sequence); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, inboxWatermarkSQL, item.Environment, item.SourceGeneration, at); err != nil {
		return err
	}
	return tx.Commit()
}
