package operationsapi

import (
	"math"
	"net/http"
	"time"
	"unicode/utf8"
)

func (a *httpAPI) registerTelemetry(mux *http.ServeMux) {
	a.register(mux, "GET", "/v1/operations/metrics", "listMetrics", func(r *http.Request) (apiResult, error) {
		from, to, metric, collection, e := metricRequest(r, time.Now())
		if e != nil {
			return apiResult{}, e
		}
		items, e := a.store.ListMetricRollups(r.Context(), from, to, metric, collection, 10000)
		if e != nil {
			return apiResult{}, e
		}
		var latest *time.Time
		buckets := map[int64]bool{}
		for _, v := range items {
			end := v.BucketStart.Add(time.Minute)
			if latest == nil || end.After(*latest) {
				latest = &end
			}
			buckets[v.BucketStart.Unix()/60] = true
		}
		evidence := ListEvidence("operations_metric_rollups", len(items), len(items), latest, 75*time.Second, "No closed one-minute metric buckets exist for the requested range.", time.Now())
		if latest != nil {
			evidence.Coverage = pointer(min(1, float64(len(buckets))/max(1, math.Ceil(to.Sub(from).Minutes()))))
			if len(items) == 10000 {
				evidence.Accuracy = "sampled"
				evidence.DegradedReason = pointer("Metric response reached the 10,000-row safety limit.")
			}
		}
		return apiResult{value: map[string]any{"rollups": items, "evidence": evidence}}, nil
	})
	a.register(mux, "GET", "/v1/operations/traces", "listTraces", func(r *http.Request) (apiResult, error) {
		now := time.Now()
		from, e := requestDate(r, "from")
		if e != nil {
			return apiResult{}, e
		}
		to, e := requestDate(r, "to")
		if e != nil {
			return apiResult{}, e
		}
		if from == nil {
			from = pointer(now.Add(-15 * time.Minute))
		}
		if to == nil {
			to = &now
		}
		if !from.Before(*to) || to.Sub(*from) > 24*time.Hour {
			return apiResult{}, HTTPError{400, "Trace range must be positive and no more than 24 hours"}
		}
		limit, before, e := pageQuery(r, 500)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListTraceSpansPage(r.Context(), *from, *to, limit, before)
		if e != nil {
			return apiResult{}, e
		}
		result := pageResponse("traces", page, "operations_trace_spans", nil, 75*time.Second, "No traces exist in the requested range.")
		result["truncated"] = page.NextCursor != nil
		result["evidence"] = TraceEvidence(page.Items, pointer(page.TotalCount), page.NextCursor != nil, now, "No traces exist in the requested range.", "The response is a paginated subset of matching trace spans.")
		return apiResult{value: result}, nil
	})
	a.register(mux, "GET", "/v1/operations/traces/{traceId}", "getTrace", func(r *http.Request) (apiResult, error) {
		id, e := requestResourceID(r, "traceId")
		if e != nil {
			return apiResult{}, e
		}
		items, e := a.store.ListTraceSpans(r.Context(), 500, &id)
		if e != nil {
			return apiResult{}, e
		}
		if len(items) == 0 {
			return apiResult{}, ErrNotFound
		}
		truncated := len(items) == 500
		var total *int
		if !truncated {
			total = pointer(len(items))
		}
		return apiResult{value: map[string]any{"traces": items, "totalCount": len(items), "truncated": truncated, "evidence": TraceEvidence(items, total, truncated, time.Now(), "Trace not found.", "Trace detail reached the 500-span safety limit.")}}, nil
	})
}
func metricRequest(r *http.Request, now time.Time) (time.Time, time.Time, *string, *string, error) {
	from, e := requestDate(r, "from")
	if e != nil {
		return time.Time{}, time.Time{}, nil, nil, e
	}
	requested, e := requestDate(r, "to")
	if e != nil {
		return time.Time{}, time.Time{}, nil, nil, e
	}
	if from == nil || requested == nil || r.URL.Query().Get("resolution") != "1m" {
		return time.Time{}, time.Time{}, nil, nil, HTTPError{400, "Metrics require ISO-8601 range and one-minute resolution"}
	}
	boundary := now.Truncate(time.Minute)
	to := *requested
	if boundary.Before(to) {
		to = boundary
	}
	to = to.Add(-time.Millisecond)
	if !from.Before(to) || to.Sub(*from) > 24*time.Hour {
		return time.Time{}, time.Time{}, nil, nil, HTTPError{400, "Metric range must be positive and no more than 24 hours"}
	}
	var metric, collection *string
	if values, ok := r.URL.Query()["metric"]; ok && len(values) > 0 {
		metric = &values[0]
	}
	if values, ok := r.URL.Query()["collection"]; ok && len(values) > 0 {
		collection = &values[0]
	}
	if metric != nil && utf8.RuneCountInString(*metric) > 160 || collection != nil && utf8.RuneCountInString(*collection) > 256 {
		return time.Time{}, time.Time{}, nil, nil, HTTPError{400, "Metric filters are too long"}
	}
	return *from, to, metric, collection, nil
}
func TraceEvidence(spans []TraceSpan, total *int, truncated bool, now time.Time, empty, partial string) EvidenceMetadata {
	var latest *time.Time
	for _, v := range spans {
		if latest == nil || v.StartedAt.After(*latest) {
			latest = pointer(v.StartedAt.Time)
		}
	}
	evidence := ListEvidence("operations_trace_spans", len(spans), len(spans), latest, 75*time.Second, empty, now)
	if latest == nil {
		return evidence
	}
	if total == nil {
		evidence.Coverage = nil
	} else {
		evidence.Coverage = pointer(min(1, float64(len(spans))/float64(max(1, *total))))
	}
	if truncated || total != nil && len(spans) < *total {
		evidence.Accuracy = "sampled"
		evidence.DegradedReason = &partial
	}
	return evidence
}
