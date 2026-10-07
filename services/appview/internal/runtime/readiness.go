package runtime

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Readiness struct {
	Store           *pdsreadstatecore.Store
	Environment     string
	Invalidate      func(context.Context, string) error
	Rebuild         func(context.Context, string) (bool, error)
	Deadline, Retry time.Duration
	ctx             context.Context
	cancel          context.CancelFunc
	mu              sync.Mutex
	closed          bool
	inflight        map[string]bool
	retryAfter      map[string]time.Time
	wg              sync.WaitGroup
}

func NewReadiness(ctx context.Context, store *pdsreadstatecore.Store, environment string, invalidate func(context.Context, string) error) *Readiness {
	ctx, cancel := context.WithCancel(ctx)
	return &Readiness{Store: store, Environment: environment, Invalidate: invalidate, Rebuild: func(ctx context.Context, viewer string) (bool, error) { return store.Reconcile(ctx, viewer, true) }, Deadline: 90 * time.Second, Retry: 30 * time.Second, ctx: ctx, cancel: cancel, inflight: map[string]bool{}, retryAfter: map[string]time.Time{}}
}
func (r *Readiness) Close() { r.mu.Lock(); r.closed = true; r.cancel(); r.mu.Unlock(); r.wg.Wait() }
func (r *Readiness) RequireReady(ctx context.Context, viewer string) error {
	now := time.Now()
	if err := r.Store.Touch(ctx, viewer, now); err != nil {
		return err
	}
	status, err := r.Store.Status(ctx, viewer)
	if err != nil {
		return err
	}
	if status.Authority != "pds" || status.ProjectionReady {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.closed && !r.inflight[viewer] && len(r.inflight) < 2 && !r.retryAfter[viewer].After(now) {
		for key, at := range r.retryAfter {
			if !at.After(now) {
				delete(r.retryAfter, key)
			}
		}
		r.inflight[viewer] = true
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			deadline := r.Deadline
			if deadline <= 0 || deadline > 90*time.Second {
				deadline = 90 * time.Second
			}
			work, cancel := context.WithTimeout(r.ctx, deadline)
			err := r.rebuild(work, viewer)
			cancel()
			r.mu.Lock()
			defer r.mu.Unlock()
			delete(r.inflight, viewer)
			if err != nil {
				if len(r.retryAfter) >= 1000 {
					oldest := ""
					for key, at := range r.retryAfter {
						if oldest == "" || at.Before(r.retryAfter[oldest]) {
							oldest = key
						}
					}
					delete(r.retryAfter, oldest)
				}
				r.retryAfter[viewer] = time.Now().Add(r.Retry)
			}
		}()
	}
	return pdsreadstatecore.ErrProjectionUnavailable
}
func (r *Readiness) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		path := req.URL.Path
		reads := strings.HasPrefix(path, "/v1/appview/") || strings.HasPrefix(path, "/xrpc/app.thesocialwire.appview.") || path == "/v1/publications/sidebar" || path == "/v1/publications/refresh" || path == "/xrpc/app.thesocialwire.publication.getSidebar" || path == "/xrpc/app.thesocialwire.publication.refreshSidebar"
		auth, ok := gatewaycore.AuthContextFrom(req.Context())
		if reads && ok && path != "/xrpc/app.thesocialwire.appview.exportReadState" {
			if err := r.RequireReady(req.Context(), auth.DID); err != nil && path != "/xrpc/app.thesocialwire.appview.getReadStateStatus" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(503)
				json.NewEncoder(w).Encode(map[string]any{"error": "ReadStateNotReady", "message": "Read state is syncing. Please retry shortly.", "requestId": w.Header().Get("X-Request-ID"), "retryable": true})
				return
			}
		}
		next.ServeHTTP(w, req)
	})
}

type recoveryLease struct {
	Name, Owner string
	Token       int64
}

func randomOwner() (string, error) {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	data[6] = (data[6] & 15) | 64
	data[8] = (data[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", data[:4], data[4:6], data[6:8], data[8:10], data[10:]), nil
}
func (r *Readiness) acquire(ctx context.Context, name, owner string, at time.Time) (*recoveryLease, error) {
	lease := recoveryLease{Name: name, Owner: owner}
	err := r.Store.DB.QueryRowContext(ctx, `INSERT INTO appview_ingestion_leases(environment,lease_name,source_generation,owner_id,fencing_token,acquired_at,lease_expires_at,released_at,updated_at)VALUES($1,$2,'pds-read-state-rebuild-v1',$3,1,$4,$5,NULL,$4) ON CONFLICT(environment,lease_name)DO UPDATE SET source_generation=EXCLUDED.source_generation,owner_id=EXCLUDED.owner_id,fencing_token=CASE WHEN appview_ingestion_leases.owner_id=EXCLUDED.owner_id AND appview_ingestion_leases.source_generation=EXCLUDED.source_generation AND appview_ingestion_leases.released_at IS NULL AND appview_ingestion_leases.lease_expires_at>$4 THEN appview_ingestion_leases.fencing_token ELSE appview_ingestion_leases.fencing_token+1 END,acquired_at=CASE WHEN appview_ingestion_leases.owner_id=EXCLUDED.owner_id AND appview_ingestion_leases.source_generation=EXCLUDED.source_generation AND appview_ingestion_leases.released_at IS NULL AND appview_ingestion_leases.lease_expires_at>$4 THEN appview_ingestion_leases.acquired_at ELSE EXCLUDED.acquired_at END,lease_expires_at=EXCLUDED.lease_expires_at,released_at=NULL,updated_at=EXCLUDED.updated_at WHERE appview_ingestion_leases.released_at IS NOT NULL OR appview_ingestion_leases.lease_expires_at<=$4 OR(appview_ingestion_leases.owner_id=EXCLUDED.owner_id AND appview_ingestion_leases.source_generation=EXCLUDED.source_generation)RETURNING fencing_token`, r.Environment, name, owner, at, at.Add(120*time.Second)).Scan(&lease.Token)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &lease, err
}
func (r *Readiness) fence(ctx context.Context, lease *recoveryLease, body func() error) error {
	tx, err := r.Store.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var token int64
	if err = tx.QueryRowContext(ctx, `SELECT fencing_token FROM appview_ingestion_leases WHERE environment=$1 AND lease_name=$2 AND owner_id=$3 AND fencing_token=$4 AND released_at IS NULL AND lease_expires_at>=$5 FOR UPDATE`, r.Environment, lease.Name, lease.Owner, lease.Token, time.Now()).Scan(&token); err != nil {
		return err
	}
	if err = body(); err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	return tx.Commit()
}
func (r *Readiness) release(leases []*recoveryLease) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, lease := range leases {
		if lease != nil {
			_, _ = r.Store.DB.ExecContext(ctx, `UPDATE appview_ingestion_leases SET released_at=$5,updated_at=$5 WHERE environment=$1 AND lease_name=$2 AND owner_id=$3 AND fencing_token=$4 AND released_at IS NULL`, r.Environment, lease.Name, lease.Owner, lease.Token, time.Now())
		}
	}
}
func (r *Readiness) rebuild(ctx context.Context, viewer string) error {
	owner, err := randomOwner()
	if err != nil {
		return err
	}
	hash := sha256.Sum256([]byte(viewer))
	lease, err := r.acquire(ctx, "pds-read-state-rebuild:"+hex.EncodeToString(hash[:]), owner, time.Now())
	if err != nil {
		return err
	}
	if lease == nil {
		return pdsreadstatecore.ErrProjectionUnavailable
	}
	leases := []*recoveryLease{lease}
	defer func() { r.release(leases) }()
	var slot *recoveryLease
	for n := 0; n < 2 && slot == nil; n++ {
		slot, err = r.acquire(ctx, fmt.Sprintf("pds-read-state-rebuild-slot-%d", n), owner, time.Now())
		if err != nil {
			return err
		}
	}
	if slot == nil {
		return pdsreadstatecore.ErrProjectionUnavailable
	}
	leases = append(leases, slot)
	if err = r.fence(ctx, slot, func() error { return nil }); err != nil {
		return err
	}
	return r.fence(ctx, lease, func() error {
		status, err := r.Store.Status(ctx, viewer)
		if err != nil {
			return err
		}
		if status.ProjectionReady {
			return nil
		}
		if r.Invalidate != nil {
			if err = r.Invalidate(ctx, viewer); err != nil {
				return err
			}
		}
		ready, err := r.Rebuild(ctx, viewer)
		if err != nil {
			return err
		}
		if !ready {
			return pdsreadstatecore.ErrProjectionUnavailable
		}
		return ctx.Err()
	})
}
