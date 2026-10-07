package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"math"
	"strconv"
	"time"
)

var databaseCostIntervals = map[string]time.Duration{"counters": time.Minute, "statements": 5 * time.Minute, "tables": 15 * time.Minute, "expiry": 30 * time.Second}
var expiryTables = []string{"content_items", "wire_items", "wire_item_aliases", "wire_rank_generations", "appview_circle_graph_snapshots", "appview_circle_edition_cache", "operations_metric_rollups", "operations_change_events", "appview_ingestion_inbox", "wire_ingestion_inbox"}

func (s *PostgresStore) databaseCostRead(ctx context.Context, operation func(context.Context, pgx.Tx) error) error {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return err
	}
	if err = operation(budget, tx); err != nil {
		return err
	}
	if err = tx.Commit(budget); err != nil {
		return err
	}
	return budget.Err()
}
func (s *PostgresStore) FetchDatabaseObservability(_ context.Context, at time.Time) *DatabaseObservabilitySnapshot {
	return s.DatabaseObservations.Snapshot(at)
}
func (s *PostgresStore) recordDatabaseObservabilityCounters(ctx context.Context, at time.Time) error {
	sample := databaseCounterSample{at: at}
	err := s.databaseCostRead(ctx, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT numbackends::bigint,current_setting('max_connections')::bigint,(xact_commit+xact_rollback)::bigint,CASE WHEN(blks_hit+blks_read)=0 THEN NULL::double precision ELSE blks_hit::double precision/(blks_hit+blks_read)::double precision END,stats_reset,(SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND state='active' AND pid<>pg_backend_pid()) FROM pg_stat_database WHERE datname=current_database()`).Scan(&sample.connections, &sample.maxConnections, &sample.transactions, &sample.cacheHitRatio, &sample.statsResetAt, &sample.activeQueries)
	})
	if err != nil {
		return err
	}
	s.DatabaseObservations.RecordCounters(sample)
	return nil
}
func (s *PostgresStore) recordDatabaseObservabilityTables(ctx context.Context, at time.Time) error {
	sample := databaseTableSample{at: at, topTables: []DatabaseTableRecordCount{}}
	err := s.databaseCostRead(ctx, func(ctx context.Context, tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT pg_database_size(current_database())::bigint,coalesce(sum(n_live_tup),0)::bigint FROM pg_stat_user_tables`).Scan(&sample.size, &sample.records)
	})
	if err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	err = s.databaseCostRead(ctx, func(ctx context.Context, tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT schemaname,relname,n_live_tup::bigint FROM pg_stat_user_tables ORDER BY n_live_tup DESC,schemaname,relname LIMIT 10`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			table := DatabaseTableRecordCount{}
			if err = rows.Scan(&table.Schema, &table.Table, &table.EstimatedRecords); err != nil {
				return err
			}
			sample.topTables = append(sample.topTables, table)
		}
		return rows.Err()
	})
	if err != nil {
		return err
	}
	s.DatabaseObservations.RecordTables(sample)
	return nil
}

// Collection groups throttle independently. Missing observations are omitted, never emitted as healthy zero.
func (s *PostgresStore) RecordDatabaseCostTelemetry(ctx context.Context, group string, at time.Time) error {
	interval, known := databaseCostIntervals[group]
	if !known {
		return errors.New("unknown database observation group")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	d := &s.DatabaseObservations
	d.mu.Lock()
	if d.running == nil {
		d.running = map[string]bool{}
		d.last = map[string]time.Time{}
	}
	if d.running[group] || !d.last[group].IsZero() && at.Sub(d.last[group]) < interval {
		d.mu.Unlock()
		return nil
	}
	d.running[group] = true
	d.last[group] = at
	d.mu.Unlock()
	defer func() { d.mu.Lock(); d.running[group] = false; d.mu.Unlock() }()
	samples := []telemetrycore.MetricSample{}
	metric := func(name string, value float64, table string) {
		dimensions := map[string]string{"environment": s.Environment, "service": "postgres"}
		if table != "" {
			dimensions["table"] = table
		}
		samples = append(samples, telemetrycore.MetricSample{Name: "socialwire.database." + name, Value: value, Dimensions: dimensions, At: at})
	}
	observe := func(operation func(context.Context, pgx.Tx) error) error {
		length := len(samples)
		d.mu.Lock()
		walBytes, walReset, walAt := d.walBytes, d.walReset, d.walAt
		d.mu.Unlock()
		err := s.databaseCostRead(ctx, operation)
		if err != nil {
			samples = samples[:length]
			d.mu.Lock()
			if group == "counters" {
				d.walBytes, d.walReset, d.walAt = walBytes, walReset, walAt
			}
			d.mu.Unlock()
		}
		return err
	}
	switch group {
	case "counters":
		_ = s.recordDatabaseObservabilityCounters(ctx, at)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_ = observe(func(ctx context.Context, tx pgx.Tx) error {
			var wal, fpi, requested, timed, failed, temp, reset float64
			err := tx.QueryRow(ctx, `SELECT w.wal_bytes::double precision,w.wal_fpi::double precision,c.num_requested::double precision,c.num_timed::double precision,a.failed_count::double precision,d.temp_bytes::double precision,extract(epoch FROM w.stats_reset)::double precision FROM pg_stat_wal w CROSS JOIN pg_stat_checkpointer c CROSS JOIN pg_stat_archiver a CROSS JOIN pg_stat_database d WHERE d.datname=current_database()`).Scan(&wal, &fpi, &requested, &timed, &failed, &temp, &reset)
			if err != nil {
				return err
			}
			for _, pair := range []struct {
				name  string
				value float64
			}{{"wal_bytes_total", wal}, {"wal_full_page_images_total", fpi}, {"checkpoints_requested_total", requested}, {"checkpoints_timed_total", timed}, {"archive_failures_total", failed}, {"temporary_bytes_total", temp}} {
				metric(pair.name, pair.value, "")
			}
			d.mu.Lock()
			if !d.walAt.IsZero() && d.walReset == reset && wal >= d.walBytes && at.After(d.walAt) {
				metric("wal_bytes_per_second", (wal-d.walBytes)/at.Sub(d.walAt).Seconds(), "")
			}
			d.walBytes, d.walReset, d.walAt = wal, reset, at
			d.mu.Unlock()
			return nil
		})
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_ = observe(func(ctx context.Context, tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT language_bucket,diagnostics->>'cycleDurationMilliseconds' FROM wire_rank_generations WHERE feed_key='wire' AND is_active=TRUE ORDER BY feed_key,language_bucket LIMIT 32`)
			if err != nil {
				return err
			}
			defer rows.Close()
			for rows.Next() {
				var language string
				var raw *string
				if err = rows.Scan(&language, &raw); err != nil {
					return err
				}
				if raw != nil {
					milliseconds, err := strconv.ParseFloat(*raw, 64)
					if err == nil && !math.IsNaN(milliseconds) && !math.IsInf(milliseconds, 0) && milliseconds >= 0 {
						samples = append(samples, telemetrycore.MetricSample{Name: "socialwire.wire.generation_duration_ms", Value: milliseconds, Dimensions: map[string]string{"environment": s.Environment, "service": "wire-worker", "language": language}, At: at})
					}
				}
			}
			return rows.Err()
		})
	case "statements":
		_ = observe(func(ctx context.Context, tx pgx.Tx) error {
			var execution, wal, temp float64
			err := tx.QueryRow(ctx, `SELECT coalesce(sum(total_exec_time),0)::double precision,coalesce(sum(wal_bytes),0)::double precision,coalesce(sum(temp_blks_written),0)::double precision FROM pg_stat_statements WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database())`).Scan(&execution, &wal, &temp)
			if err != nil {
				return err
			}
			metric("statement_execution_ms_total", execution, "")
			metric("statement_wal_bytes_total", wal, "")
			metric("statement_temp_blocks_written_total", temp, "")
			return nil
		})
	case "tables":
		_ = s.recordDatabaseObservabilityTables(ctx, at)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		_ = observe(func(ctx context.Context, tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT relname,pg_total_relation_size(relid)::double precision,n_dead_tup::double precision,n_tup_upd::double precision,n_tup_hot_upd::double precision FROM pg_stat_user_tables WHERE schemaname='public' AND relname IN ('wire_ranked_items','wire_items','wire_item_aliases','wire_link_metadata_cache','wire_ingestion_inbox','appview_ingestion_inbox','content_items','operations_change_events','operations_metric_rollups','wire_edition_module_items') ORDER BY relname`)
			if err != nil {
				return err
			}
			defer rows.Close()
			for rows.Next() {
				var table string
				var bytes, dead, updates, hot float64
				if err = rows.Scan(&table, &bytes, &dead, &updates, &hot); err != nil {
					return err
				}
				metric("table_bytes", bytes, table)
				metric("dead_rows_estimated", dead, table)
				metric("updates_total", updates, table)
				metric("hot_updates_total", hot, table)
			}
			return rows.Err()
		})
	case "expiry":
		d.mu.Lock()
		table := expiryTables[d.nextExpiry]
		d.nextExpiry = (d.nextExpiry + 1) % len(expiryTables)
		d.mu.Unlock()
		count, truncated, err := s.databaseExpiryBacklog(ctx, table, at, 1000)
		if err == nil {
			metric("expired_rows_lower_bound", float64(min(count, 1000)), table)
			value := 0.0
			if truncated {
				value = 1
			}
			metric("expired_rows_truncated", value, table)
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return s.RecordTelemetryBatch(ctx, samples)
}
