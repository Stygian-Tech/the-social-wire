package socialdraftcore

import (
	"context"
	"database/sql"
	"time"
)

const cleanupDeleteTimeout = 5 * time.Second
const cleanupPersistTimeout = 2 * time.Second

// Cleanup claims in due-time order with SKIP LOCKED. Each delete has a shorter
// deadline than the sweep and its transaction, reserving time to persist backoff.
func (s *Service) Cleanup(ctx context.Context, limit int) (int, error) {
	if e := s.available(); e != nil {
		return 0, e
	}
	if limit < 1 || limit > 1000 {
		return 0, ErrInvalid
	}
	release, e := s.admit(ctx, "")
	if e != nil {
		return 0, e
	}
	defer release()
	completed := 0
	var retryError error
	for i := 0; i < limit; i++ {
		if e := ctx.Err(); e != nil {
			return completed, e
		}
		claimed, removed, e := s.cleanupOne(ctx)
		if e == ErrUnavailable {
			retryError = e
			continue
		}
		if e != nil {
			return completed, e
		}
		if !claimed {
			return completed, retryError
		}
		if removed {
			completed++
		}
	}
	return completed, retryError
}

func (s *Service) cleanupOne(ctx context.Context) (claimed, removed bool, err error) {
	// database/sql automatically rolls back when the BeginTx context is cancelled.
	// A bounded independent lifetime is essential: a cancelled sweep must not
	// invalidate the transaction before its already-claimed job can be deferred.
	jobCtx, cancelJob := context.WithTimeout(context.WithoutCancel(ctx), cleanupDeleteTimeout+cleanupPersistTimeout)
	defer cancelJob()
	jobDeadline, _ := jobCtx.Deadline()
	claimCtx, cancelClaim := context.WithDeadline(ctx, jobDeadline)
	defer cancelClaim()
	tx, e := s.db.BeginTx(jobCtx, nil)
	if e != nil {
		return false, false, e
	}
	defer tx.Rollback()
	var owner string
	e = tx.QueryRowContext(claimCtx, `SELECT a.owner FROM private_social_draft_cleanup c JOIN private_social_draft_accounts a ON a.owner=c.owner WHERE c.available_at<=now() ORDER BY c.available_at,c.owner,c.asset_id FOR UPDATE OF a SKIP LOCKED LIMIT 1`).Scan(&owner)
	if e == sql.ErrNoRows {
		return false, false, nil
	}
	if e != nil {
		return false, false, e
	}
	var id, key string
	e = tx.QueryRowContext(claimCtx, `SELECT c.asset_id::text,a.object_key FROM private_social_draft_cleanup c JOIN private_social_draft_assets a USING(owner,asset_id) WHERE c.owner=$1 AND c.available_at<=now() ORDER BY c.available_at,c.asset_id LIMIT 1 FOR UPDATE OF c,a`, owner).Scan(&id, &key)
	// The owner's stable row may have matched an earlier statement snapshot even
	// though another replica completed its last job just before we took its lock.
	if e == sql.ErrNoRows {
		return true, false, nil
	}
	if e != nil {
		return true, false, e
	}
	var referenced bool
	if e = tx.QueryRowContext(claimCtx, `SELECT EXISTS(SELECT 1 FROM private_social_draft_bindings WHERE owner=$1 AND asset_id=$2)`, owner, id).Scan(&referenced); e != nil {
		return true, false, e
	}
	var deleteError error
	if !referenced {
		if _, e = tx.ExecContext(claimCtx, `UPDATE private_social_draft_assets SET state='deleted' WHERE owner=$1 AND asset_id=$2`, owner, id); e != nil {
			return true, false, e
		}
		deleteCtx, cancelDelete := cleanupObjectContext(ctx, jobCtx)
		if deleteError = deleteCtx.Err(); deleteError == nil {
			deleteError = s.objects.Delete(deleteCtx, key)
		}
		cancelDelete()
	}
	// Persist even if the sweep was cancelled while S3 was running. This context
	// and the transaction lifetime are both bounded; AfterFunc also bounds Commit,
	// whose database/sql API has no separate context parameter.
	persistCtx, cancelPersist := context.WithTimeout(context.WithoutCancel(ctx), cleanupPersistTimeout)
	defer cancelPersist()
	stop := context.AfterFunc(persistCtx, cancelJob)
	defer stop()
	if deleteError != nil {
		_, e = tx.ExecContext(persistCtx, `UPDATE private_social_draft_cleanup SET attempts=LEAST(attempts+1,30),available_at=now()+interval '1 minute'*LEAST(60,power(2,LEAST(attempts,6))) WHERE owner=$1 AND asset_id=$2`, owner, id)
	} else {
		if !referenced {
			// Only confirmed physical deletion releases byte/count quota and metadata.
			_, e = tx.ExecContext(persistCtx, `UPDATE private_social_draft_assets SET state='purged',metadata=''::bytea WHERE owner=$1 AND asset_id=$2`, owner, id)
		}
		if e == nil {
			_, e = tx.ExecContext(persistCtx, `DELETE FROM private_social_draft_cleanup WHERE owner=$1 AND asset_id=$2`, owner, id)
		}
	}
	if e != nil {
		return true, false, e
	}
	if e = tx.Commit(); e != nil {
		return true, false, e
	}
	if deleteError != nil {
		return true, false, ErrUnavailable
	}
	return true, !referenced, nil
}

func cleanupObjectContext(sweep, job context.Context) (context.Context, context.CancelFunc) {
	budget := cleanupDeleteTimeout
	if deadline, ok := sweep.Deadline(); ok {
		if remaining := time.Until(deadline) / 2; remaining < budget {
			budget = remaining
		}
	}
	if deadline, ok := job.Deadline(); ok {
		if remaining := time.Until(deadline) - cleanupPersistTimeout; remaining < budget {
			budget = remaining
		}
	}
	return context.WithTimeout(sweep, budget)
}
