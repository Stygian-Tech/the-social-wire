package socialdraftcore

import (
	"context"
	"database/sql"
	"errors"
	"sync"

	"github.com/jackc/pgx/v5/pgconn"
)

// Admission happens before obtaining a database connection. Fail fast rather
// than accumulate waiters, disk spools, or connections behind one slow owner.
// Cross-replica database lock contention is separately bounded by lock_timeout.
type admission struct {
	mu     sync.Mutex
	active int
	owners map[string]bool
}

func (s *Service) admit(ctx context.Context, owner string) (func(), error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	limit := 8
	if max := s.db.Stats().MaxOpenConnections; max > 0 && max/4 < limit {
		limit = max / 4
		if limit < 1 {
			limit = 1
		}
	}
	s.admission.mu.Lock()
	if s.admission.active >= limit || (owner != "" && s.admission.owners[owner]) {
		s.admission.mu.Unlock()
		return nil, ErrUnavailable
	}
	if s.admission.owners == nil {
		s.admission.owners = map[string]bool{}
	}
	s.admission.active++
	if owner != "" {
		s.admission.owners[owner] = true
	}
	s.admission.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			s.admission.mu.Lock()
			s.admission.active--
			delete(s.admission.owners, owner)
			s.admission.mu.Unlock()
		})
	}, nil
}

type transaction struct {
	*sql.Tx
	release func()
}

func (t *transaction) Commit() error   { defer t.release(); return t.Tx.Commit() }
func (t *transaction) Rollback() error { defer t.release(); return t.Tx.Rollback() }
func lockError(e error) error {
	var pg *pgconn.PgError
	if errors.As(e, &pg) && pg.Code == "55P03" {
		return ErrUnavailable
	}
	return e
}

func (s *Service) begin(ctx context.Context, owner string) (*transaction, error) {
	if e := s.available(); e != nil {
		return nil, e
	}
	if !validOwner(owner) {
		return nil, ErrInvalid
	}
	release, e := s.admit(ctx, owner)
	if e != nil {
		return nil, e
	}
	tx, e := s.beginAdmitted(ctx, owner)
	if e != nil {
		release()
		return nil, e
	}
	return &transaction{Tx: tx, release: release}, nil
}

// The caller owns admission for the entire body-spooling and finalization phase.
func (s *Service) beginAdmitted(ctx context.Context, owner string) (*sql.Tx, error) {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return nil, e
	}
	if _, e = tx.ExecContext(ctx, `SET LOCAL lock_timeout='100ms'`); e == nil {
		_, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_accounts(owner) VALUES($1) ON CONFLICT DO NOTHING`, owner)
	}
	if e == nil {
		_, e = tx.ExecContext(ctx, `SELECT owner FROM private_social_draft_accounts WHERE owner=$1 FOR UPDATE NOWAIT`, owner)
	}
	if e != nil {
		tx.Rollback()
		return nil, lockError(e)
	}
	return tx, nil
}

type rowReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}
