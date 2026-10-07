package runtime

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"time"
)

func (h *Host) registerHealth(mux *http.ServeMux) {
	for _, path := range []string{"/health", "/livez"} {
		mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			status := "ok"
			if r.URL.Path == "/livez" {
				status = "live"
			}
			healthJSON(w, 200, map[string]string{"status": status, "service": "appview"})
		})
	}
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		if h.DB.PingContext(ctx) != nil {
			healthJSON(w, 503, map[string]string{"status": "not_ready", "service": "appview"})
			return
		}
		healthJSON(w, 200, map[string]string{"status": "ready", "service": "appview"})
	})
	mux.HandleFunc("GET /freshness", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		at := time.Now().UTC()
		freshness, completeness := "unknown", "healthy"
		var committed sql.NullTime
		err := h.DB.QueryRowContext(ctx, `SELECT last_committed_at FROM appview_ingestion_stream_state WHERE environment=$1 AND source='jetstream'`, h.Config.Environment).Scan(&committed)
		if err != nil && err != sql.ErrNoRows {
			healthJSON(w, 500, map[string]string{"error": "Internal Server Error"})
			return
		}
		if committed.Valid {
			freshness = "healthy"
			if at.Sub(committed.Time) > 300*time.Second {
				freshness = "degraded"
			}
		}
		var confirmed bool
		err = h.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM (SELECT status FROM appview_ingestion_gaps WHERE environment=$1 ORDER BY detected_at DESC,id DESC LIMIT 100) gaps WHERE status='confirmed')`, h.Config.Environment).Scan(&confirmed)
		if err != nil {
			healthJSON(w, 500, map[string]string{"error": "Internal Server Error"})
			return
		}
		if confirmed {
			completeness = "degraded"
		}
		healthJSON(w, 200, map[string]string{"service": "appview", "freshness": freshness, "completeness": completeness, "checkedAt": at.Format(time.RFC3339)})
	})
}
func healthJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func (h *Host) heartbeat(ctx context.Context) {
	started := time.Now().UTC()
	for {
		work, cancel := context.WithTimeout(ctx, 5*time.Second)
		at := time.Now().UTC()
		readiness, dependency := "healthy", "ready"
		if h.DB.PingContext(work) != nil {
			readiness, dependency = "degraded", "unavailable"
		}
		deps, _ := json.Marshal(map[string]string{"appview_database": dependency, "projection_freshness": "unmeasured", "projection_completeness": "unknown", "observed_at": at.Format(time.RFC3339), "valid_until": at.Add(30 * time.Second).Format(time.RFC3339)})
		_, _ = h.DB.ExecContext(work, `INSERT INTO operations_service_state(service,environment,instance_id,liveness,readiness,freshness,completeness,dependency_state,version,started_at,heartbeat_at)VALUES('appview',$1,$2,'healthy',$3,'unknown','unknown',$4::jsonb,$5,$6,$7)ON CONFLICT(service,environment,instance_id)DO UPDATE SET liveness=EXCLUDED.liveness,readiness=EXCLUDED.readiness,freshness=EXCLUDED.freshness,completeness=EXCLUDED.completeness,dependency_state=EXCLUDED.dependency_state,version=EXCLUDED.version,heartbeat_at=EXCLUDED.heartbeat_at`, h.Config.Environment, h.Config.InstanceID, readiness, string(deps), h.Config.Version, started, at)
		cancel()
		timer := time.NewTimer(15 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
