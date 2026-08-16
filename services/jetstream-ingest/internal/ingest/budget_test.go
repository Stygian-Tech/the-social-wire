package ingest

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"testing"
	"time"
)

func TestReplayBudgetEnforcesIncidentAndRollingLimits(t *testing.T) {
	budget := NewReplayBudget(10, 21)
	now := time.Unix(1_700_000_000, 0).UTC()
	budget.now = func() time.Time { return now }
	if err := budget.Add(10); err != nil {
		t.Fatal(err)
	}
	if err := budget.Add(1); !errors.Is(err, ErrIncidentBudgetExceeded) {
		t.Fatalf("expected incident limit, got %v", err)
	}
	budget.ResetIncident()
	if err := budget.Add(10); err != nil {
		t.Fatal(err)
	}
	budget.ResetIncident()
	if err := budget.Add(1); !errors.Is(err, ErrDailyBudgetExceeded) {
		t.Fatalf("expected daily limit, got %v", err)
	}
	now = now.Add(25 * time.Hour)
	if wait := budget.WaitForDailyCapacity(); wait != 0 {
		t.Fatalf("expired bytes still consume budget for %s", wait)
	}
}

func TestReplayBudgetIncidentLimitDoesNotExpireWithTime(t *testing.T) {
	budget := NewReplayBudget(10, 100)
	now := time.Unix(1_700_000_000, 0).UTC()
	budget.now = func() time.Time { return now }
	if err := budget.Add(10); err != nil {
		t.Fatal(err)
	}

	now = now.Add(25 * time.Hour)
	if err := budget.Add(1); !errors.Is(err, ErrIncidentBudgetExceeded) {
		t.Fatalf("expected durable incident limit after daily window elapsed, got %v", err)
	}
}

func TestBudgetTransportCoalescesDurableUsageWrites(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), 1024*1024)
	writes := 0
	var recorded int64
	transport := BudgetTransport{
		Base: roundTripperFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(payload)), ContentLength: int64(len(payload)), Header: make(http.Header)}, nil
		}),
		Budget:      NewReplayBudget(2<<20, 2<<20),
		RecordUsage: func(_ context.Context, bytes int64) error { writes++; recorded += bytes; return nil },
	}
	request, err := http.NewRequest(http.MethodGet, "https://jetstream.us-west.bsky.network/xrpc/network.bsky.jetstream.getSegment", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(io.Discard, response.Body); err != nil {
		t.Fatal(err)
	}
	if err := response.Body.Close(); err != nil {
		t.Fatal(err)
	}
	if writes != 1 || recorded != int64(len(payload)) {
		t.Fatalf("writes=%d recorded=%d", writes, recorded)
	}
}

func TestTransportEvidenceCountsRetriesAndMidRangeResumes(t *testing.T) {
	evidence := NewTransportEvidence()
	request, _ := http.NewRequest(http.MethodGet, "https://jetstream.example/xrpc/network.bsky.jetstream.getSegment?id=one", nil)
	request.Header.Set("Range", "bytes=0-99")
	evidence.ObserveRequest(request)
	evidence.ObserveRequest(request)
	resumed := request.Clone(context.Background())
	resumed.Header = request.Header.Clone()
	resumed.Header.Set("Range", "bytes=50-99")
	evidence.ObserveRequest(resumed)
	evidence.ObserveResponse(&http.Response{Header: http.Header{"Etag": []string{"\"segment-v1\""}}})
	snapshot := evidence.Snapshot()
	if snapshot.RetryCount != 1 || snapshot.RangeResumeCount != 1 || snapshot.ETag != "\"segment-v1\"" {
		t.Fatalf("evidence = %#v", snapshot)
	}
}

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (function roundTripperFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}
