package appviewworkercore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

type outcomeProjector struct {
	changed bool
	err     error
}

func (p outcomeProjector) Apply(context.Context, thinappviewcore.InboxItem) error { return p.err }
func (p outcomeProjector) ApplyWithOutcome(context.Context, thinappviewcore.InboxItem) (bool, error) {
	return p.changed, p.err
}

type acknowledgementProbe struct {
	processorRepository
	buffer   *TelemetryBuffer
	ackError error
	t        *testing.T
}

func (r *acknowledgementProbe) Applied(ctx context.Context, item thinappviewcore.InboxItem, worker string, expiry, at time.Time) error {
	if r.buffer.Snapshot().QueueDepth != 0 {
		r.t.Fatal("success metrics emitted before durable ack")
	}
	if r.ackError != nil {
		return r.ackError
	}
	return r.processorRepository.Applied(ctx, item, worker, expiry, at)
}
func TestCommitMetricsRepresentOutcomeAfterAck(t *testing.T) {
	collection, operation := "site.standard.document", "create"
	for _, test := range []struct {
		name                  string
		changed               bool
		projectionErr, ackErr error
		wantCount             int
		result                string
	}{{"indexed", true, nil, nil, 4, "indexed"}, {"skipped", false, nil, nil, 2, "skipped"}, {"projection_failure", false, errors.New("publisher secret"), nil, 1, ""}, {"ack_failure", true, nil, thinappviewcore.ErrStaleInboxLease, 1, ""}} {
		t.Run(test.name, func(t *testing.T) {
			var samples []MetricSample
			buffer := &TelemetryBuffer{Export: func(_ context.Context, batch []MetricSample) error { samples = append(samples, batch...); return nil }}
			repo := &acknowledgementProbe{buffer: buffer, t: t, ackError: test.ackErr}
			p := InboxProcessor{Repository: repo, Projector: outcomeProjector{test.changed, test.projectionErr}, WorkerID: "fixture", LeaseDuration: time.Minute, ProjectionTimeout: time.Second, Telemetry: buffer}
			_ = p.Process(context.Background(), thinappviewcore.InboxItem{EventKind: "commit", Collection: &collection, Operation: &operation, EventTime: time.Now().Add(-time.Second)})
			if _, err := buffer.Flush(context.Background()); err != nil {
				t.Fatal(err)
			}
			if len(samples) != test.wantCount {
				t.Fatalf("metrics %d want %d", len(samples), test.wantCount)
			}
			for _, sample := range samples {
				if sample.Name == "socialwire.ingestion.results_total" {
					if test.result != "" && sample.Dimensions["indexing_result"] != test.result {
						t.Fatal(sample)
					}
					if test.result == "" && sample.Dimensions["result"] != "error" {
						t.Fatal(sample)
					}
				}
			}
		})
	}
}
