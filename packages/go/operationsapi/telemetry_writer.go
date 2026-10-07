package operationsapi

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
)

func (s *PostgresStore) RecordTelemetryBatch(ctx context.Context, signals []telemetrycore.MetricSample) error {
	if len(signals) == 0 {
		return nil
	}
	if s.TelemetryExporter == nil {
		return errors.New("Operations telemetry exporter is unavailable")
	}
	return s.TelemetryExporter.Export(ctx, signals)
}
func (s *PostgresStore) RecordMetric(ctx context.Context, sample telemetrycore.MetricSample) error {
	return s.RecordTelemetryBatch(ctx, []telemetrycore.MetricSample{sample})
}
func (s *PostgresStore) RecordEvent(ctx context.Context, event TelemetryEvent) error {
	return s.RecordTelemetryBatch(ctx, []telemetrycore.MetricSample{{Event: &telemetrycore.EventSample{ID: event.ID, Environment: event.Environment, Service: event.Service, InstanceID: event.InstanceID, Name: event.Name, OccurredAt: event.OccurredAt.Time, RequestID: event.RequestID, TraceID: event.TraceID, Attributes: event.Attributes}}})
}
func (s *PostgresStore) RecordTraceSpan(ctx context.Context, span TraceSpan) error {
	return s.RecordTelemetryBatch(ctx, []telemetrycore.MetricSample{{Span: &telemetrycore.SpanSample{ID: span.ID, Environment: span.Environment, TraceID: span.TraceID, ParentSpanIDValue: span.ParentSpanID, Service: span.Service, Name: span.Name, StartedAt: span.StartedAt.Time, ExpiresAt: span.ExpiresAt.Time, DurationMS: span.DurationMS, Status: span.Status, Attributes: span.Attributes}}})
}
