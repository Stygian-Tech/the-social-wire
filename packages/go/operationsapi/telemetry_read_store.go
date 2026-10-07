package operationsapi

import (
	"context"
	"encoding/json"
	"time"
)

const traceColumns = `id,trace_id,parent_span_id,service,name,started_at,duration_ms,status,attributes::text,expires_at`

func scanTrace(row interface{ Scan(...any) error }, env string) (TraceSpan, error) {
	span := TraceSpan{Environment: env}
	var started, expires time.Time
	var attributes string
	err := row.Scan(&span.ID, &span.TraceID, &span.ParentSpanID, &span.Service, &span.Name, &started, &span.DurationMS, &span.Status, &attributes, &expires)
	span.StartedAt = WireTime{started}
	span.ExpiresAt = WireTime{expires}
	if json.Unmarshal([]byte(attributes), &span.Attributes) != nil || span.Attributes == nil {
		span.Attributes = map[string]string{}
	}
	return span, err
}
func (s *PostgresStore) ListTraceSpans(ctx context.Context, limit int, traceID *string) ([]TraceSpan, error) {
	rows, err := s.DB.Query(ctx, `SELECT `+traceColumns+` FROM operations_trace_spans WHERE environment=$1 AND ($2::text IS NULL OR trace_id=$2::text) ORDER BY started_at DESC LIMIT $3`, s.Environment, traceID, max(1, min(limit, 500)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	spans := []TraceSpan{}
	for rows.Next() {
		span, err := scanTrace(rows, s.Environment)
		if err != nil {
			return nil, err
		}
		spans = append(spans, span)
	}
	return spans, rows.Err()
}
func (s *PostgresStore) ListTraceSpansPage(ctx context.Context, start, end time.Time, limit int, before *string) (Page[TraceSpan], error) {
	limit = max(1, min(limit, 500))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[TraceSpan]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	rows, err := s.DB.Query(ctx, `SELECT `+traceColumns+` FROM operations_trace_spans WHERE environment=$1 AND started_at>=$2 AND started_at<=$3 AND ($4::timestamptz IS NULL OR started_at<$4::timestamptz OR (started_at=$4::timestamptz AND id<$5::text)) ORDER BY started_at DESC,id DESC LIMIT $6`, s.Environment, start, end, date, id, limit+1)
	if err != nil {
		return Page[TraceSpan]{}, err
	}
	spans := []TraceSpan{}
	for rows.Next() {
		span, err := scanTrace(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[TraceSpan]{}, err
		}
		spans = append(spans, span)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[TraceSpan]{}, err
	}
	page := Page[TraceSpan]{Items: spans}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM operations_trace_spans WHERE environment=$1 AND started_at>=$2 AND started_at<=$3`, s.Environment, start, end).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(spans) > limit {
		page.Items = spans[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.StartedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
func (s *PostgresStore) ListTraceSpansWindow(ctx context.Context, start, end time.Time, limit int) ([]TraceSpan, error) {
	rows, err := s.DB.Query(ctx, `SELECT `+traceColumns+` FROM operations_trace_spans WHERE environment=$1 AND started_at>=$2 AND started_at<=$3 ORDER BY started_at ASC LIMIT $4`, s.Environment, start, end, max(1, min(limit, 500)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	spans := []TraceSpan{}
	for rows.Next() {
		span, err := scanTrace(rows, s.Environment)
		if err != nil {
			return nil, err
		}
		spans = append(spans, span)
	}
	return spans, rows.Err()
}
func (s *PostgresStore) ListMetricRollups(ctx context.Context, start, end time.Time, metric, collection *string, limit int) ([]MetricRollup, error) {
	rows, err := s.DB.Query(ctx, `SELECT bucket_start,metric_name,dimensions::text,sample_count,value_sum,value_min,value_max FROM operations_metric_rollups WHERE environment=$1 AND bucket_start>=$2 AND bucket_start<=$3 AND ($4::text IS NULL OR metric_name=$4::text) AND ($5::text IS NULL OR dimensions->>'collection'=$5::text) ORDER BY bucket_start ASC,metric_name ASC,dimensions_hash ASC LIMIT $6`, s.Environment, start, end, metric, collection, max(1, min(limit, 10000)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []MetricRollup{}
	for rows.Next() {
		rollup := MetricRollup{Environment: s.Environment}
		var bucket time.Time
		var dimensions string
		if err = rows.Scan(&bucket, &rollup.MetricName, &dimensions, &rollup.SampleCount, &rollup.ValueSum, &rollup.ValueMin, &rollup.ValueMax); err != nil {
			return nil, err
		}
		rollup.BucketStart = WireTime{bucket}
		if json.Unmarshal([]byte(dimensions), &rollup.Dimensions) != nil || rollup.Dimensions == nil {
			rollup.Dimensions = map[string]string{}
		}
		result = append(result, rollup)
	}
	return result, rows.Err()
}
func (s *PostgresStore) ListGapInvestigationEvents(ctx context.Context, start, end time.Time, limit int) ([]TelemetryEvent, error) {
	rows, err := s.DB.Query(ctx, `SELECT id,service,environment,instance_id,event_name,occurred_at,request_id,trace_id,attributes::text FROM operations_events WHERE environment=$1 AND occurred_at>=$2 AND occurred_at<=$3 AND event_name IN ('jetstream.disconnected','jetstream.connected','commit.failed') ORDER BY occurred_at ASC LIMIT $4`, s.Environment, start, end, max(1, min(limit, 500)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []TelemetryEvent{}
	for rows.Next() {
		event := TelemetryEvent{}
		var occurred time.Time
		var attributes string
		if err = rows.Scan(&event.ID, &event.Service, &event.Environment, &event.InstanceID, &event.Name, &occurred, &event.RequestID, &event.TraceID, &attributes); err != nil {
			return nil, err
		}
		event.OccurredAt = WireTime{occurred}
		if json.Unmarshal([]byte(attributes), &event.Attributes) != nil || event.Attributes == nil {
			event.Attributes = map[string]string{}
		}
		result = append(result, event)
	}
	return result, rows.Err()
}
