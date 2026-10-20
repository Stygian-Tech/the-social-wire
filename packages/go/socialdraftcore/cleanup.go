package socialdraftcore

import (
	"context"
	"database/sql"
)

// Cleanup claims an owner lock with SKIP LOCKED before touching assets, using
// the same lock order as foreground operations. S3 deletes are idempotent and
// happen before committing the outbox acknowledgement. Crashes safely retry.
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
		tx, e := s.db.BeginTx(ctx, nil)
		if e != nil {
			return completed, e
		}
		var owner string
		e = tx.QueryRowContext(ctx, `SELECT a.owner FROM private_social_draft_cleanup c JOIN private_social_draft_accounts a ON a.owner=c.owner WHERE c.available_at<=now() ORDER BY c.available_at,c.owner,c.asset_id FOR UPDATE OF a SKIP LOCKED LIMIT 1`).Scan(&owner)
		if e == sql.ErrNoRows {
			tx.Rollback()
			return completed, retryError
		}
		if e != nil {
			tx.Rollback()
			return completed, e
		}
		var id, key string
		e = tx.QueryRowContext(ctx, `SELECT c.asset_id::text,a.object_key FROM private_social_draft_cleanup c JOIN private_social_draft_assets a USING(owner,asset_id) WHERE c.owner=$1 AND c.available_at<=now() ORDER BY c.available_at,c.asset_id LIMIT 1 FOR UPDATE OF c,a`, owner).Scan(&id, &key)
		// The owner's row is stable, so the statement's earlier EXISTS snapshot
		// can still see a job another worker completed before we took its lock.
		if e == sql.ErrNoRows {
			tx.Rollback()
			continue
		}
		if e != nil {
			tx.Rollback()
			return completed, e
		}
		var referenced bool
		e = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM private_social_draft_bindings WHERE owner=$1 AND asset_id=$2)`, owner, id).Scan(&referenced)
		if e != nil {
			tx.Rollback()
			return completed, e
		}
		removed := false
		if referenced {
			_, e = tx.ExecContext(ctx, `DELETE FROM private_social_draft_cleanup WHERE owner=$1 AND asset_id=$2`, owner, id)
		} else {
			// Revoke before the external operation, including failed deletion attempts.
			_, e = tx.ExecContext(ctx, `UPDATE private_social_draft_assets SET state='deleted' WHERE owner=$1 AND asset_id=$2`, owner, id)
			if e == nil {
				if de := s.objects.Delete(ctx, key); de != nil {
					_, e = tx.ExecContext(ctx, `UPDATE private_social_draft_cleanup SET attempts=LEAST(attempts+1,30),available_at=now()+interval '1 minute'*LEAST(60,power(2,LEAST(attempts,6))) WHERE owner=$1 AND asset_id=$2`, owner, id)
					if e == nil {
						e = tx.Commit()
					}
					if e != nil {
						tx.Rollback()
						return completed, e
					}
					retryError = ErrUnavailable
					continue
				}
				// Confirmed physical deletion releases byte/count quota and
				// erases sensitive metadata, retaining only an immutable ID tombstone.
				_, e = tx.ExecContext(ctx, `UPDATE private_social_draft_assets SET state='purged',metadata=''::bytea WHERE owner=$1 AND asset_id=$2`, owner, id)
				if e != nil {
					tx.Rollback()
					return completed, e
				}
				_, e = tx.ExecContext(ctx, `DELETE FROM private_social_draft_cleanup WHERE owner=$1 AND asset_id=$2`, owner, id)
				if e == nil {
					removed = true
				}
			}
		}
		if e != nil {
			tx.Rollback()
			return completed, e
		}
		if e = tx.Commit(); e != nil {
			return completed, e
		}
		if removed {
			completed++
		}
	}
	return completed, retryError
}
