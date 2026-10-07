package appviewworkercore

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"math"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode"
)

type metricRollup struct {
	name, hash, payload string
	bucket              time.Time
	count               int
	sum, min, max       float64
}

func (h *Host) exportTelemetry(ctx context.Context, samples []MetricSample) error {
	budget, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	grouped := map[string]*metricRollup{}
	for _, sample := range samples {
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
		if env, ok := dimensions["environment"]; ok && env != h.Config.Environment {
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
	for _, key := range order {
		value := grouped[key]
		if _, err := tx.ExecContext(budget, `INSERT INTO operations_metric_rollups(environment,bucket_start,metric_name,dimensions_hash,dimensions,sample_count,value_sum,value_min,value_max,histogram_buckets,expires_at)VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8,$9,'{}',$10)ON CONFLICT(environment,bucket_start,metric_name,dimensions_hash)DO UPDATE SET sample_count=operations_metric_rollups.sample_count+EXCLUDED.sample_count,value_sum=operations_metric_rollups.value_sum+EXCLUDED.value_sum,value_min=LEAST(operations_metric_rollups.value_min,EXCLUDED.value_min),value_max=GREATEST(operations_metric_rollups.value_max,EXCLUDED.value_max)`, h.Config.Environment, value.bucket, value.name, value.hash, value.payload, value.count, value.sum, value.min, value.max, value.bucket.Add(90*24*time.Hour)); err != nil {
			return rollbackError(err)
		}
	}
	// A lost COMMIT reply is ambiguous. Never classify it as replayable contention.
	return tx.Commit()
}

func telemetryErrorCategory(err error) string {
	sanitize := func(raw string, bound int) string {
		result := []rune{}
		for _, c := range raw {
			if unicode.IsLetter(c) || unicode.IsDigit(c) {
				result = append(result, unicode.ToLower(c))
			} else {
				result = append(result, '_')
			}
			if len(result) == bound {
				break
			}
		}
		return string(result)
	}
	var postgres *pgconn.PgError
	if errors.As(err, &postgres) {
		parts := []string{"postgres", strings.ToLower(postgres.Code)}
		for _, value := range []string{postgres.TableName, postgres.ColumnName} {
			if value != "" {
				parts = append(parts, sanitize(value, 32))
			}
		}
		return strings.Join(parts, "_")
	}
	if err == nil {
		return "unknown"
	}
	name := reflect.TypeOf(err).String()
	parts := strings.Split(name, ".")
	return sanitize(parts[len(parts)-1], 64)
}
