package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"time"
)

const gatewayHeartbeatInterval = 5 * time.Second

func (s *Server) Heartbeat(ctx context.Context, instance, version string, started time.Time) {
	for {
		work, cancel := context.WithTimeout(ctx, 5*time.Second)
		_ = s.heartbeatOnce(work, instance, version, started)
		cancel()
		timer := time.NewTimer(gatewayHeartbeatInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
func (s *Server) heartbeatOnce(ctx context.Context, instance, version string, started time.Time) error {
	// Never publish replacement evidence when the canonical Operations DB probe fails.
	if s.DB == nil {
		return errors.New("Operations database unavailable")
	}
	if err := s.DB.PingContext(ctx); err != nil {
		return err
	}
	at := time.Now().UTC()
	live, ready, fresh, complete := "degraded", "unknown", "unknown", "unknown"
	deps := map[string]string{"appview": "missing", "service_probe": "degraded"}
	if s.Config.AppViewURL != "" {
		status, err := s.probeStatus(ctx, s.Config.AppViewURL)
		if err != nil {
			live, ready = "degraded", "degraded"
			deps = map[string]string{"service_probe": "failed:dependency_unavailable"}
		} else {
			live, ready = "healthy", "healthy"
			deps["appview"] = "ready"
			deps["service_probe"] = "ready"
			e := s.Evidence(at)
			complete = e.Completeness
			pool := e.PoolReadiness
			if e.ValidUntil == nil || e.ValidUntil.Before(at.Add(30*time.Second)) {
				complete = "unknown"
				if e.CheckedAt != nil {
					pool = "stale"
				}
			}
			deps["projection_pool"], deps["ingestion_completeness"] = pool, complete
			if e.CheckedAt != nil {
				deps["ingestion_observed_at"] = e.CheckedAt.UTC().Format(time.RFC3339)
			}
			if e.ValidUntil != nil {
				deps["ingestion_valid_until"] = e.ValidUntil.UTC().Format(time.RFC3339)
			}
			if status < 200 || status >= 300 {
				live, ready = "degraded", "degraded"
				deps["appview"] = fmt.Sprintf("failed_http_%d", status)
				deps["service_probe"] = "degraded"
				if complete == "healthy" {
					complete = "degraded"
				}
			}
		}
	}
	deps["operations_database"] = "ready"
	if s.Telemetry != nil {
		evidence, invalid, failed, lost := gatewayTelemetryEvidence(s.Telemetry.Snapshot(), time.Now())
		for key, value := range evidence {
			deps[key] = value
		}
		if invalid {
			if fresh == "healthy" {
				fresh = "unknown"
			}
			if complete == "healthy" {
				complete = "unknown"
			}
		} else {
			if failed && fresh == "healthy" {
				fresh = "degraded"
			}
			if lost && complete == "healthy" {
				complete = "degraded"
			}
		}
	}
	deps["observed_at"] = at.Format(time.RFC3339Nano)
	deps["valid_until"] = at.Add(30 * time.Second).Format(time.RFC3339Nano)
	raw, err := json.Marshal(deps)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO operations_service_state(service,environment,instance_id,liveness,readiness,freshness,completeness,dependency_state,version,started_at,heartbeat_at)VALUES('gateway',$1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9,$10)ON CONFLICT(service,environment,instance_id)DO UPDATE SET liveness=EXCLUDED.liveness,readiness=EXCLUDED.readiness,freshness=EXCLUDED.freshness,completeness=EXCLUDED.completeness,dependency_state=EXCLUDED.dependency_state,version=EXCLUDED.version,heartbeat_at=EXCLUDED.heartbeat_at`, s.Config.Environment, instance, live, ready, fresh, complete, string(raw), version, started, time.Now().UTC())
	if err != nil {
		return err
	}
	if s.Telemetry != nil {
		for dim, state := range map[string]string{"liveness": live, "readiness": ready, "freshness": fresh, "completeness": complete} {
			s.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.service.health.samples_total", Value: 1, Dimensions: map[string]string{"service": "gateway", "dimension": dim, "state": state}})
		}
	}
	return nil
}
