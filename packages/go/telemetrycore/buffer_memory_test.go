package telemetrycore

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func TestTelemetryFlushReleasesConsumedPayloads(t *testing.T) {
	for _, batchSize := range []int{1, 2} {
		buffer := TelemetryBuffer{BatchSize: batchSize, Export: func(_ context.Context, batch []MetricSample) error {
			if batch[0].Dimensions["payload"] == "" {
				t.Fatal("export lost payload")
			}
			return nil
		}}
		sample := MetricSample{Name: "fixture", Dimensions: map[string]string{"payload": strings.Repeat("x", 1024)}}
		sample.Span = &SpanSample{Attributes: map[string]string{"payload": strings.Repeat("s", 1024)}}
		sample.Event = &EventSample{Attributes: map[string]string{"payload": strings.Repeat("e", 1024)}}

		buffer.Enqueue(sample)
		buffer.Enqueue(sample)
		storage := buffer.queue
		if n, err := buffer.Flush(context.Background()); n != batchSize || err != nil {
			t.Fatal(n, err)
		}
		for _, consumed := range storage[:batchSize] {
			if !reflect.DeepEqual(consumed, telemetryQueued{}) {
				t.Fatal("consumed queue slot retains exported payload")
			}
		}
		if batchSize == 1 {
			if len(buffer.queue) != 1 || buffer.queue[0].sample.Dimensions["payload"] == "" {
				t.Fatal("pending payload lost")
			}
			if n, err := buffer.Flush(context.Background()); n != 1 || err != nil {
				t.Fatal(n, err)
			}
		}
		if buffer.queue != nil {
			t.Fatal("drained queue retains backing allocation")
		}
	}
}

func BenchmarkTelemetryDrainedQueueRetention(b *testing.B) {
	payload := strings.Repeat("x", 1024)
	retained := 0
	b.ReportAllocs()
	for range b.N {
		buffer := TelemetryBuffer{BatchSize: 64, Export: func(context.Context, []MetricSample) error { return nil }}
		for range 64 {
			buffer.Enqueue(MetricSample{Name: "fixture", Dimensions: map[string]string{"payload": strings.Clone(payload)}})
		}
		storage := buffer.queue
		_, err := buffer.Flush(context.Background())
		if err != nil {
			b.Fatal(err)
		}
		retained = 0
		for _, slot := range storage {
			retained += len(slot.sample.Dimensions["payload"])
		}
	}
	b.ReportMetric(float64(retained), "retained-payload-B")
}
