package runner

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

type observedEvent struct {
	lane  indexingworkercore.LaneName
	event operationscore.LeaseEvent
}
type observer struct {
	db                          *sql.DB
	environment, owner          string
	logger                      *slog.Logger
	queue                       chan observedEvent
	lastCapture, lastRenewalLog map[indexingworkercore.LaneName]time.Time
	renewals                    map[indexingworkercore.LaneName]int
}

func newObserver(db *sql.DB, environment, owner string, logger *slog.Logger) *observer {
	return &observer{db: db, environment: environment, owner: owner, logger: logger, queue: make(chan observedEvent, 64), lastCapture: map[indexingworkercore.LaneName]time.Time{}, lastRenewalLog: map[indexingworkercore.LaneName]time.Time{}, renewals: map[indexingworkercore.LaneName]int{}}
}

// Control callbacks cannot wait on diagnostics, logging, or the workload pools.
func (o *observer) event(lane indexingworkercore.LaneName, event operationscore.LeaseEvent) {
	select {
	case o.queue <- observedEvent{lane, event}:
	default:
	}
}
func (o *observer) run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case observation := <-o.queue:
			o.record(ctx, observation)
		}
	}
}
func (o *observer) record(ctx context.Context, observation observedEvent) {
	lane, event := observation.lane, observation.event
	now := time.Now()
	role := "indexing.appview-coordinator"
	if lane == indexingworkercore.Wire {
		role = "indexing.wire-materializer"
	}
	if event.Err != nil && strings.HasSuffix(event.Phase, "_failed") && now.Sub(o.lastCapture[lane]) >= time.Minute {
		o.lastCapture[lane] = now
		o.capture(ctx, role)
	}
	if event.Phase == "renewed" {
		o.renewals[lane]++
		if o.lastRenewalLog[lane].IsZero() {
			o.lastRenewalLog[lane] = now
		}
		if now.Sub(o.lastRenewalLog[lane]) >= time.Minute {
			o.logger.Info("Indexing successful lease renewals", "role", role, "count", o.renewals[lane])
			o.renewals[lane] = 0
			o.lastRenewalLog[lane] = now
		}
		return
	}
	if event.Phase != "acquiring" && event.Phase != "standby" {
		o.logger.Info("Indexing role lifecycle", "role", role, "owner_id", safeLabel(o.owner, 255), "event", event.Phase)
	}
}
func safeLabel(value string, limit int) string {
	var b strings.Builder
	count := 0
	for _, r := range value {
		if count >= limit {
			break
		}
		count++
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_.:", r) {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

type backend struct {
	PID            int      `json:"pid"`
	WaitType       *string  `json:"waitEventType"`
	Wait           *string  `json:"waitEvent"`
	Application    *string  `json:"applicationName"`
	QueryID        *string  `json:"queryID"`
	TransactionAge *float64 `json:"transactionAgeMilliseconds"`
	QueryAge       *float64 `json:"queryAgeMilliseconds"`
	Blockers       []int    `json:"blockingPIDs"`
	Truncated      bool     `json:"blockersTruncated"`
}

func applicationCategory(name *string) string {
	if name == nil {
		return "unknown"
	}
	// Only known service categories become dimensions; operator-supplied names
	// never enter a diagnostic log verbatim.
	switch *name {
	case "indexing-authority", "indexing-lease-diagnostics", "Coordinator", "coordinator", "coordinator-appview", "coordinator-wire", "coordinator-lease-diagnostics", "Projection-Pool", "projection-pool", "App-View", "appview", "thin-appview", "Gateway", "gateway", "Operations", "operations", "Ops", "Charybdis", "charybdis", "Wire", "wire-worker", "Corpus-Edge", "Wire-Corpus-Edge", "wire-corpus-edge", "Jetstream-V2-Ingest", "jetstream-ingest", "Ingress-Controller", "ingress-controller", "Database-Migrator", "appview.Ingress-Controller", "wire.Ingress-Controller", "wire-live.Ingress-Controller", "appview.ingress-controller", "wire.ingress-controller", "wire-live.ingress-controller", "wire-external.Ingress-Controller", "wire-publication.Ingress-Controller", "wire-publicationwest.Ingress-Controller", "wire-external.ingress-controller", "wire-publication.ingress-controller", "wire-publicationwest.ingress-controller", "appview.Jetstream-V2-Ingest", "wire.The-Wire-Global-Ingest-Production", "wire.The-Wire-Live-Ingest-Production", "The-Wire-Worker-Production", "The-Wire-Global-Ingest-Production", "The-Wire-Live-Ingest-Production":
		return *name
	}
	parts := strings.Split(*name, ":")
	if len(parts) == 2 {
		base := parts[0]
		if applicationCategory(&base) != "unknown" {
			switch parts[1] {
			case "authority", "lease-diagnostics", "coordinator-appview", "projection-pool-appview", "appview-worker", "wire-combined", "wire-rank", "wire-drain":
				return *name
			}
		}
	}
	return "unknown"
}
func (o *observer) capture(parent context.Context, role string) {
	started := time.Now()
	ctx, stop := context.WithTimeout(parent, 3*time.Second)
	defer stop()
	attributes := []any{"environment", o.environment, "role", role, "process_time", started.UTC().Format(time.RFC3339Nano)}
	snapshot, err := o.loadSnapshot(ctx, role)
	if err != nil {
		attributes = append(attributes, "availability", "unavailable", "failure", failureCategory(err))
	} else {
		attributes = append(attributes, "availability", "available", "snapshot", snapshot)
	}
	attributes = append(attributes, "capture_ms", float64(time.Since(started))/float64(time.Millisecond))
	o.logger.Warn("Coordinator lease failure diagnostic", attributes...)
}
func failureCategory(err error) string {
	if errors.Is(err, operationscore.ErrLeaseConflict) {
		return "leaseConflict"
	}
	if errors.Is(err, operationscore.ErrAuthorityExpired) {
		return "authorityExpired"
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "operationTimedOut"
	}
	var postgres *pgconn.PgError
	if errors.As(err, &postgres) {
		switch postgres.Code {
		case "55P03":
			return "lockTimeout"
		case "57014":
			return "statementCancelled"
		case "40P01":
			return "deadlock"
		case "40001":
			return "serializationFailure"
		case "08000", "08003", "08006", "08001", "08004", "57P01", "57P02", "57P03":
			return "connectionUnavailable"
		}
	}
	var network net.Error
	if errors.As(err, &network) {
		return "connectionUnavailable"
	}
	return "unknown"
}
func (o *observer) loadSnapshot(ctx context.Context, role string) (map[string]any, error) {
	tx, err := o.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for _, setting := range []string{"SET LOCAL statement_timeout='2500ms'", "SET LOCAL lock_timeout='500ms'"} {
		if _, err := tx.ExecContext(ctx, setting); err != nil {
			return nil, err
		}
	}
	var databaseTime time.Time
	var owner sql.NullString
	var token sql.NullInt64
	var expires sql.NullTime
	var total, active, idle, waiting, candidates int64
	var raw string
	if err := tx.QueryRowContext(ctx, diagnosticQuery, o.environment, role).Scan(&databaseTime, &owner, &token, &expires, &total, &active, &idle, &waiting, &raw, &candidates); err != nil {
		return nil, err
	}
	var backends []backend
	if err := json.Unmarshal([]byte(raw), &backends); err != nil {
		return nil, err
	}
	samples := []map[string]any{}
	for _, v := range backends {
		if len(samples) >= 16 {
			break
		}
		queryID := "unavailable"
		if v.QueryID != nil {
			if parsed, err := strconv.ParseInt(*v.QueryID, 10, 64); err == nil {
				queryID = strconv.FormatInt(parsed, 10)
			}
		}
		waitType, wait := "none", "none"
		if v.WaitType != nil {
			waitType = safeLabel(*v.WaitType, 64)
		}
		if v.Wait != nil {
			wait = safeLabel(*v.Wait, 64)
		}
		blockers := v.Blockers
		if len(blockers) > 16 {
			blockers = blockers[:16]
		}
		sample := map[string]any{"pid": v.PID, "application_name": applicationCategory(v.Application), "query_id": queryID, "wait_event_type": waitType, "wait_event": wait, "blocking_pids": blockers, "blocking_pids_truncated": v.Truncated || len(v.Blockers) > 16}
		if v.TransactionAge != nil {
			sample["transaction_age_ms"] = max(0, *v.TransactionAge)
		}
		if v.QueryAge != nil {
			sample["query_age_ms"] = max(0, *v.QueryAge)
		}
		samples = append(samples, sample)
	}
	snapshot := map[string]any{"database_time": databaseTime.UTC().Format(time.RFC3339Nano), "lease_present": owner.Valid, "connections_total": total, "connections_active": active, "connections_idle": idle, "connections_waiting": waiting, "backend_samples_truncated": candidates > 16, "backends": samples}
	if owner.Valid {
		snapshot["owner_id"] = safeLabel(owner.String, 255)
	}
	if token.Valid {
		snapshot["fencing_token"] = token.Int64
	}
	if expires.Valid {
		snapshot["lease_expires_at"] = expires.Time.UTC().Format(time.RFC3339Nano)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}
