package telemetrycore

import (
	"context"
	"errors"
	"math/rand/v2"
	"sync"
	"time"
)

type SpanSample struct {
	// ParentSpanIDValue preserves an explicitly present empty value; legacy string callers remain supported.
	ParentSpanIDValue                                             *string
	ID, Environment, TraceID, ParentSpanID, Service, Name, Status string
	StartedAt, ExpiresAt                                          time.Time
	DurationMS                                                    float64
	Attributes                                                    map[string]string
}

type EventSample struct {
	ID, Environment, Service, InstanceID, Name string
	OccurredAt                                 time.Time
	RequestID, TraceID                         *string
	Attributes                                 map[string]string
}

type MetricSample struct {
	Event      *EventSample
	Span       *SpanSample
	Name       string
	Value      float64
	Dimensions map[string]string
	At         time.Time
}
type TelemetrySnapshot struct {
	QueueDepth, InFlight, Capacity, Dropped, ConsecutiveFailures int
	LastSuccess, LastDrop, LastRecovered                         *time.Time
}
type telemetryQueued struct {
	sample   MetricSample
	enqueued time.Time
}
type TelemetryBuffer struct {
	mu                                   sync.Mutex
	queue                                []telemetryQueued
	inFlight, dropped, failures          int
	lastSuccess, lastDrop, lastRecovered *time.Time
	retryAfter                           time.Time
	Capacity, BatchSize, MaximumAttempts int
	BatchDelay                           time.Duration
	Export                               func(context.Context, []MetricSample) error
	Now                                  func() time.Time
}
type telemetryExportError struct {
	cause error
	safe  bool
}

func (e *telemetryExportError) Error() string { return e.cause.Error() }
func (e *telemetryExportError) Unwrap() error { return e.cause }
func (t *TelemetryBuffer) clock() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}
func (t *TelemetryBuffer) capacity() int {
	if t.Capacity > 0 {
		return t.Capacity
	}
	return 4096
}
func (t *TelemetryBuffer) batch() int {
	n := t.BatchSize
	if n <= 0 {
		n = 100
	}
	return min(n, t.capacity())
}
func (t *TelemetryBuffer) drop(n int) {
	t.dropped += n
	at := t.clock()
	t.lastDrop = &at
	t.lastRecovered = nil
}
func (t *TelemetryBuffer) Enqueue(sample MetricSample) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.queue)+t.inFlight >= t.capacity() {
		t.drop(1)
		return false
	}
	if sample.At.IsZero() {
		sample.At = t.clock()
	}
	dimensions := map[string]string{}
	for k, v := range sample.Dimensions {
		dimensions[k] = v
	}
	sample.Dimensions = dimensions
	if sample.Span != nil {
		copy := *sample.Span
		if copy.ParentSpanIDValue != nil {
			value := *copy.ParentSpanIDValue
			copy.ParentSpanIDValue = &value
		}
		copy.Attributes = map[string]string{}
		for k, v := range sample.Span.Attributes {
			copy.Attributes[k] = v
		}
		sample.Span = &copy
	}
	if sample.Event != nil {
		copy := *sample.Event
		copy.Attributes = map[string]string{}
		for k, v := range sample.Event.Attributes {
			copy.Attributes[k] = v
		}
		if copy.RequestID != nil {
			v := *copy.RequestID
			copy.RequestID = &v
		}
		if copy.TraceID != nil {
			v := *copy.TraceID
			copy.TraceID = &v
		}
		sample.Event = &copy
	}
	t.queue = append(t.queue, telemetryQueued{sample: sample, enqueued: t.clock()})
	return true
}
func (t *TelemetryBuffer) Snapshot() TelemetrySnapshot {
	t.mu.Lock()
	defer t.mu.Unlock()
	clone := func(value *time.Time) *time.Time {
		if value == nil {
			return nil
		}
		copy := *value
		return &copy
	}
	return TelemetrySnapshot{len(t.queue), t.inFlight, t.capacity(), t.dropped, t.failures, clone(t.lastSuccess), clone(t.lastDrop), clone(t.lastRecovered)}
}
func (t *TelemetryBuffer) Run(ctx context.Context) error {
	if t.Export == nil {
		return errors.New("telemetry exporter unavailable")
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		t.mu.Lock()
		delay := t.BatchDelay
		if delay <= 0 {
			delay = time.Second
		}
		ready := len(t.queue) > 0 && (len(t.queue) >= t.batch() || t.clock().Sub(t.queue[0].enqueued) >= delay)
		t.mu.Unlock()
		if ready {
			_, _ = t.Flush(ctx)
		}
		if err := pause(ctx, 100*time.Millisecond); err != nil {
			return err
		}
	}
}
func (t *TelemetryBuffer) Flush(ctx context.Context) (int, error) {
	t.mu.Lock()
	if t.inFlight > 0 || len(t.queue) == 0 || t.clock().Before(t.retryAfter) {
		t.mu.Unlock()
		return 0, nil
	}
	count := min(t.batch(), len(t.queue))
	queued := append([]telemetryQueued(nil), t.queue[:count]...)
	t.queue = t.queue[count:]
	t.inFlight = count
	t.mu.Unlock()
	batch := make([]MetricSample, count)
	for i, q := range queued {
		batch[i] = q.sample
	}
	attempts := t.MaximumAttempts
	if attempts <= 0 {
		attempts = 5
	}
	var last error
	for attempt := 0; attempt < attempts; attempt++ {
		last = t.Export(ctx, batch)
		t.mu.Lock()
		if last == nil {
			t.inFlight = 0
			at := t.clock()
			t.failures = 0
			t.retryAfter = time.Time{}
			t.lastSuccess = &at
			if len(t.queue) == 0 && t.lastDrop != nil && t.lastRecovered == nil && at.After(*t.lastDrop) {
				t.lastRecovered = &at
			}
			t.mu.Unlock()
			return count, nil
		}
		t.failures++
		var failure *telemetryExportError
		safe := errors.As(last, &failure) && failure.safe
		if !safe || ctx.Err() != nil {
			t.drop(count)
			t.inFlight = 0
			t.mu.Unlock()
			return 0, last
		}
		if attempt+1 == attempts {
			t.queue = append(queued, t.queue...)
			t.inFlight = 0
			t.retryAfter = t.clock().Add(5 * time.Second)
			t.mu.Unlock()
			return 0, last
		}
		t.mu.Unlock()
		base := time.Duration(min(5000, 100*(1<<min(attempt, 5)))) * time.Millisecond
		if err := pause(ctx, base+time.Duration(rand.Int64N(max(1, int64(base/4))))); err != nil {
			t.mu.Lock()
			t.drop(count)
			t.inFlight = 0
			t.mu.Unlock()
			return 0, err
		}
	}
	return 0, last
}

func pause(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
