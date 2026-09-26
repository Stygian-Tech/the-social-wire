package store

import (
	"context"
	"database/sql"
	"log/slog"
	"time"
)

type PoolOptions struct {
	MaxOpen     int
	MaxIdle     int
	IdleTimeout time.Duration
}

func postgresComponentApplicationName(service, component string) string {
	// Put the lane first so truncating a long provider service name cannot collapse
	// distinct pools into one pg_stat_activity application name.
	return postgresApplicationName(component + "." + postgresApplicationName(service))
}

func poolLogValues(stats, previous sql.DBStats) []any {
	utilization := float64(0)
	if stats.MaxOpenConnections > 0 {
		utilization = min(1, float64(stats.InUse)/float64(stats.MaxOpenConnections))
	}
	return []any{"db_pool_max", stats.MaxOpenConnections, "db_pool_open", stats.OpenConnections,
		"db_pool_in_use", stats.InUse, "db_pool_idle", stats.Idle, "db_pool_utilization", utilization,
		"db_pool_wait_count", max(0, stats.WaitCount-previous.WaitCount),
		"db_pool_wait_ms", max(0, (stats.WaitDuration - previous.WaitDuration).Milliseconds())}
}

// One fixed-cardinality sample per lane per minute; sampling never acquires a
// database connection and therefore remains observable under pool saturation.
func (p *Postgres) MonitorPool(ctx context.Context, logger *slog.Logger) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	previous := p.db.Stats()
	previousProcessing := p.wirePreprocessing.snapshot()
	values := append(poolLogValues(previous, previous), wirePreprocessingLogValues(p.wireCompactIngestEnabled, previousProcessing, wirePreprocessingSnapshot{})...)
	logger.Info("ingress database pool", values...)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			stats := p.db.Stats()
			processing := p.wirePreprocessing.snapshot()
			values := append(poolLogValues(stats, previous), wirePreprocessingLogValues(p.wireCompactIngestEnabled, processing, previousProcessing)...)
			logger.Info("ingress database pool", values...)
			previous = stats
			previousProcessing = processing
		}
	}
}
