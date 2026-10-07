// Package topicworkercore implements the optional Finance and Sports background lanes.
package topicworkercore

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

type Worker struct {
	DB                                          *sql.DB
	env                                         map[string]string
	policy                                      financecore.ProviderPolicy
	financeProjectionMu, sportsProjectionMu     sync.Mutex
	financeMaterializerMu, sportsMaterializerMu sync.Mutex
	providerMu                                  sync.Mutex
	financeCursor, sportsCursor                 *cursor
	lastFinanceRefresh                          *time.Time
	HTTP                                        ProviderTransport
}
type cursor struct {
	Date time.Time
	Key  string
}

func NewWorker(db *sql.DB, env map[string]string) (*Worker, error) {
	if db == nil {
		return nil, errors.New("topic worker requires database")
	}
	copyEnv := map[string]string{}
	for k, v := range env {
		copyEnv[k] = v
	}
	return &Worker{DB: db, env: copyEnv, policy: financecore.NewProviderPolicy(env), HTTP: NewHTTPTransport()}, nil
}
func mode(env map[string]string, key string) string {
	switch env[key] {
	case "shadow", "api", "visible":
		return env[key]
	default:
		return "off"
	}
}
func (w *Worker) financeEnabled() bool {
	return mode(w.env, "FINANCE_FEED_MODE") != "off" && w.env["FINANCE_CATALOG_RIGHTS_CONFIRMED"] == "true"
}
func (w *Worker) sportsEnabled() bool { return mode(w.env, "SPORTS_FEED_MODE") != "off" }

// Project attempts both independent projection lanes, preserving Sports progress
// when Finance rejects a catalog or source row.
func (w *Worker) Project(ctx context.Context, at time.Time) error {
	financeErr := w.ProjectFinance(ctx, at)
	if ctx.Err() != nil {
		return errors.Join(financeErr, ctx.Err())
	}
	return errors.Join(financeErr, w.ProjectSports(ctx, at))
}
func (w *Worker) ProjectFinance(ctx context.Context, at time.Time) error {
	w.financeProjectionMu.Lock()
	defer w.financeProjectionMu.Unlock()
	if !w.financeEnabled() {
		return nil
	}
	return w.projectFinance(ctx, at)
}
func (w *Worker) ProjectSports(ctx context.Context, at time.Time) error {
	w.sportsProjectionMu.Lock()
	defer w.sportsProjectionMu.Unlock()
	if !w.sportsEnabled() {
		return nil
	}
	return w.projectSports(ctx, at)
}
func (w *Worker) Materialize(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	financeErr := w.MaterializeFinance(ctx, authority, at)
	if ctx.Err() != nil {
		return errors.Join(financeErr, ctx.Err())
	}
	return errors.Join(financeErr, w.MaterializeSports(ctx, authority, at))
}
func (w *Worker) MaterializeFinance(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	w.financeMaterializerMu.Lock()
	defer w.financeMaterializerMu.Unlock()
	if !w.financeEnabled() {
		return nil
	}
	if err := w.refreshFinance(ctx, authority, at); err != nil {
		return err
	}
	return w.materializeFinance(ctx, authority, at)
}
func (w *Worker) MaterializeSports(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	w.sportsMaterializerMu.Lock()
	defer w.sportsMaterializerMu.Unlock()
	if !w.sportsEnabled() {
		return nil
	}
	if err := w.refreshSportsCatalog(ctx, authority, at); err != nil {
		return err
	}
	return w.materializeSports(ctx, authority, at)
}
func (w *Worker) RefreshProviders(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	w.providerMu.Lock()
	defer w.providerMu.Unlock()
	if !w.sportsEnabled() {
		return nil
	}
	return w.refreshSportsProviders(ctx, authority, at)
}
func fence(ctx context.Context, tx *sql.Tx, authority *operationscore.RoleLeaseAuthority) error {
	if authority == nil {
		return errors.New("topic publication requires coordinator authority")
	}
	return operationscore.LockRoleLeaseFence(ctx, tx, *authority, false)
}

// RefreshCatalog runs before ranking, so a failed Wire cycle cannot postpone a new
// reviewed Sports manifest. Finance refresh remains gated by its materializer rights.
func (w *Worker) RefreshCatalog(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	w.sportsMaterializerMu.Lock()
	defer w.sportsMaterializerMu.Unlock()
	if !w.sportsEnabled() {
		return nil
	}
	return w.refreshSportsCatalog(ctx, authority, at)
}
