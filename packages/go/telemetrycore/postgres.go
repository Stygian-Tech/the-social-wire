package telemetrycore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"math"
	"sort"
	"strings"
	"time"
)

type metricRollup struct {
	name, hash, payload string
	bucket              time.Time
	count               int
	sum, min, max       float64
}

type PostgresExporter struct {
	DB          *sql.DB
	Environment string
}

func (h *PostgresExporter) Export(ctx context.Context, samples []MetricSample) error {
	budget, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	grouped := map[string]*metricRollup{}
	spans := []SpanSample{}
	events := []EventSample{}
	for _, sample := range samples {
		if sample.Event != nil {
			if sample.Span != nil || sample.Event.Environment != h.Environment {
				return errors.New("invalid telemetry event")
			}
			events = append(events, *sample.Event)
			continue
		}
		if env, ok := sample.Dimensions["environment"]; ok && env != h.Environment {
			return errors.New("telemetry environment mismatch")
		}

		if sample.Span != nil {
			span := *sample.Span
			if span.Environment != h.Environment || math.IsNaN(span.DurationMS) || math.IsInf(span.DurationMS, 0) {
				return errors.New("invalid telemetry span")
			}
			spans = append(spans, span)
			continue
		}
		if math.IsNaN(sample.Value) || math.IsInf(sample.Value, 0) {
			return errors.New("nonfinite telemetry sample")
		}
		dimensions := map[string]string{}
		keys := []string{}
		for key := range sample.Dimensions {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys[:min(32, len(keys))] {
			lower := strings.ToLower(key)
			prohibited := false
			for _, token := range []string{"authorization", "dpop", "cookie", "token", "secret", "password", "record", "body"} {
				prohibited = prohibited || strings.Contains(lower, token)
			}
			if !prohibited {
				value := []rune(sample.Dimensions[key])
				dimensions[key] = string(value[:min(256, len(value))])
			}
		}
		if env, ok := dimensions["environment"]; ok && env != h.Environment {
			return errors.New("telemetry environment mismatch")
		}
		keys = keys[:0]
		for key := range dimensions {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		components := []string{}
		for _, key := range keys {
			components = append(components, key+"="+dimensions[key])
		}
		digest := sha256.Sum256([]byte(strings.Join(components, "&")))
		hash := hex.EncodeToString(digest[:12])
		encoded, err := json.Marshal(dimensions)
		if err != nil {
			return err
		}
		name := []rune(sample.Name)
		bounded := string(name[:min(160, len(name))])
		bucket := sample.At.UTC().Truncate(time.Minute)
		key := bucket.Format(time.RFC3339) + "|" + bounded + "|" + hash
		if existing := grouped[key]; existing != nil {
			existing.count++
			existing.sum += sample.Value
			existing.min = math.Min(existing.min, sample.Value)
			existing.max = math.Max(existing.max, sample.Value)
		} else {
			grouped[key] = &metricRollup{bounded, hash, string(encoded), bucket, 1, sample.Value, sample.Value, sample.Value}
		}
	}
	order := []string{}
	for key := range grouped {
		order = append(order, key)
	}
	sort.Strings(order)
	// Pre-encode bindings before acquiring locks. Every exporter uses identities first,
	// then shared rollup keys, with one stable order across 250-row chunks.
	queries, err := prepareTelemetryQueries(h.Environment, events, spans, grouped, order)
	if err != nil {
		return err
	}
	tx, err := h.DB.BeginTx(budget, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rollbackError := func(failure error) error {
		rolledBack := tx.Rollback() == nil
		var postgres *pgconn.PgError
		safe := rolledBack && errors.As(failure, &postgres) && (postgres.Code == "55P03" || postgres.Code == "40P01" || postgres.Code == "40001" || postgres.Code == "57014")
		if rolledBack && errors.Is(failure, context.DeadlineExceeded) {
			safe = true
		}
		return &telemetryExportError{failure, safe}
	}
	if _, err := tx.ExecContext(budget, "SET LOCAL statement_timeout='2s'"); err != nil {
		return rollbackError(err)
	}
	for _, query := range queries {
		if _, err := tx.ExecContext(budget, query.sql, query.args...); err != nil {
			return rollbackError(err)
		}
	}
	// A lost COMMIT reply is ambiguous. Never classify it as replayable contention.
	return tx.Commit()
}
