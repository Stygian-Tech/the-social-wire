package telemetrycore

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

type telemetryQuery struct {
	sql  string
	args []any
}

func boundedAttributes(input map[string]string) map[string]string {
	keys := []string{}
	for key := range input {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := map[string]string{}
	for _, key := range keys[:min(32, len(keys))] {
		lower := strings.ToLower(key)
		blocked := false
		for _, token := range []string{"authorization", "dpop", "cookie", "token", "secret", "password", "record", "body"} {
			blocked = blocked || strings.Contains(lower, token)
		}
		if !blocked {
			runes := []rune(input[key])
			result[key] = string(runes[:min(256, len(runes))])
		}
	}
	return result
}
func prepareTelemetryQueries(env string, events []EventSample, spans []SpanSample, metrics map[string]*metricRollup, order []string) ([]telemetryQuery, error) {
	sort.SliceStable(events, func(i, j int) bool { return events[i].ID < events[j].ID })
	sort.SliceStable(spans, func(i, j int) bool { return spans[i].ID < spans[j].ID })
	queries := []telemetryQuery{}
	for offset := 0; offset < len(events); offset += 250 {
		chunk := events[offset:min(offset+250, len(events))]
		ids := []string{}
		services := []string{}
		instances := []string{}
		names := []string{}
		times := []time.Time{}
		requests := []string{}
		hasRequests := []bool{}
		traces := []string{}
		hasTraces := []bool{}
		attributes := []string{}
		expires := []time.Time{}
		for _, e := range chunk {
			raw, err := json.Marshal(boundedAttributes(e.Attributes))
			if err != nil {
				return nil, err
			}
			ids = append(ids, e.ID)
			services = append(services, e.Service)
			instances = append(instances, e.InstanceID)
			names = append(names, boundedName(e.Name))
			times = append(times, e.OccurredAt)
			requests = append(requests, optionalString(e.RequestID))
			hasRequests = append(hasRequests, e.RequestID != nil)
			traces = append(traces, optionalString(e.TraceID))
			hasTraces = append(hasTraces, e.TraceID != nil)
			attributes = append(attributes, string(raw))
			expires = append(expires, e.OccurredAt.Add(30*24*time.Hour))
		}
		queries = append(queries, telemetryQuery{`INSERT INTO operations_events(id,service,environment,instance_id,event_name,occurred_at,request_id,trace_id,attributes,expires_at) SELECT sample.id,sample.service,$1,sample.instance_id,sample.event_name,sample.occurred_at,CASE WHEN sample.has_request_id THEN sample.request_id END,CASE WHEN sample.has_trace_id THEN sample.trace_id END,sample.attributes::jsonb,sample.expires_at FROM unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::timestamptz[],$7::text[],$8::boolean[],$9::text[],$10::boolean[],$11::text[],$12::timestamptz[]) WITH ORDINALITY AS sample(id,service,instance_id,event_name,occurred_at,request_id,has_request_id,trace_id,has_trace_id,attributes,expires_at,ordinal) ORDER BY sample.ordinal ON CONFLICT(environment,id) DO NOTHING`, []any{env, ids, services, instances, names, times, requests, hasRequests, traces, hasTraces, attributes, expires}})
	}
	for offset := 0; offset < len(spans); offset += 250 {
		chunk := spans[offset:min(offset+250, len(spans))]
		ids := []string{}
		traces := []string{}
		parents := []string{}
		hasParents := []bool{}
		services := []string{}
		names := []string{}
		times := []time.Time{}
		durations := []float64{}
		statuses := []string{}
		attributes := []string{}
		expires := []time.Time{}
		for _, e := range chunk {
			raw, err := json.Marshal(boundedAttributes(e.Attributes))
			if err != nil {
				return nil, err
			}
			ids = append(ids, e.ID)
			traces = append(traces, e.TraceID)
			parent := e.ParentSpanID
			if e.ParentSpanIDValue != nil {
				parent = *e.ParentSpanIDValue
			}
			parents = append(parents, parent)
			hasParents = append(hasParents, e.ParentSpanIDValue != nil || e.ParentSpanID != "")
			services = append(services, e.Service)
			names = append(names, e.Name)
			times = append(times, e.StartedAt)
			durations = append(durations, e.DurationMS)
			statuses = append(statuses, e.Status)
			attributes = append(attributes, string(raw))
			expires = append(expires, e.ExpiresAt)
		}
		queries = append(queries, telemetryQuery{`INSERT INTO operations_trace_spans(environment,id,trace_id,parent_span_id,service,name,started_at,duration_ms,status,attributes,expires_at) SELECT $1,sample.id,sample.trace_id,CASE WHEN sample.has_parent_span_id THEN sample.parent_span_id END,sample.service,sample.name,sample.started_at,sample.duration_ms,sample.status,sample.attributes::jsonb,sample.expires_at FROM unnest($2::text[],$3::text[],$4::text[],$5::text[],$6::text[],$7::timestamptz[],$8::double precision[],$9::text[],$10::text[],$11::timestamptz[],$12::boolean[]) WITH ORDINALITY AS sample(id,trace_id,parent_span_id,service,name,started_at,duration_ms,status,attributes,expires_at,has_parent_span_id,ordinal) ORDER BY sample.ordinal ON CONFLICT(environment,id) DO NOTHING`, []any{env, ids, traces, parents, services, names, times, durations, statuses, attributes, expires, hasParents}})
	}
	for offset := 0; offset < len(order); offset += 250 {
		chunk := order[offset:min(offset+250, len(order))]
		buckets := []time.Time{}
		names, hashes, payloads := []string{}, []string{}, []string{}
		counts := []int64{}
		sums, mins, maxs := []float64{}, []float64{}, []float64{}
		expires := []time.Time{}
		for _, key := range chunk {
			m := metrics[key]
			buckets = append(buckets, m.bucket)
			names = append(names, m.name)
			hashes = append(hashes, m.hash)
			payloads = append(payloads, m.payload)
			counts = append(counts, int64(m.count))
			sums = append(sums, m.sum)
			mins = append(mins, m.min)
			maxs = append(maxs, m.max)
			expires = append(expires, m.bucket.Add(90*24*time.Hour))
		}
		queries = append(queries, telemetryQuery{`INSERT INTO operations_metric_rollups(environment,bucket_start,metric_name,dimensions_hash,dimensions,sample_count,value_sum,value_min,value_max,histogram_buckets,expires_at) SELECT $1,sample.bucket_start,sample.metric_name,sample.dimensions_hash,sample.dimensions::jsonb,sample.sample_count,sample.value_sum,sample.value_min,sample.value_max,'{}'::jsonb,sample.expires_at FROM unnest($2::timestamptz[],$3::text[],$4::text[],$5::text[],$6::bigint[],$7::double precision[],$8::double precision[],$9::double precision[],$10::timestamptz[]) WITH ORDINALITY AS sample(bucket_start,metric_name,dimensions_hash,dimensions,sample_count,value_sum,value_min,value_max,expires_at,ordinal) ORDER BY sample.ordinal ON CONFLICT(environment,bucket_start,metric_name,dimensions_hash) DO UPDATE SET sample_count=operations_metric_rollups.sample_count+EXCLUDED.sample_count,value_sum=operations_metric_rollups.value_sum+EXCLUDED.value_sum,value_min=LEAST(operations_metric_rollups.value_min,EXCLUDED.value_min),value_max=GREATEST(operations_metric_rollups.value_max,EXCLUDED.value_max)`, []any{env, buckets, names, hashes, payloads, counts, sums, mins, maxs, expires}})
	}
	return queries, nil
}
func optionalString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
func boundedName(value string) string {
	runes := []rune(value)
	return string(runes[:min(160, len(runes))])
}
