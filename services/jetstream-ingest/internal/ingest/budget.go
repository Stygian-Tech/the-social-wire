package ingest

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	ErrIncidentBudgetExceeded = errors.New("Jetstream replay incident byte budget exceeded")
	ErrDailyBudgetExceeded    = errors.New("Jetstream replay rolling daily byte budget exceeded")
)

type byteBucket struct {
	minute time.Time
	bytes  int64
}

type ReplayUsageBucket struct {
	StartedAt time.Time
	Bytes     int64
}

type ReplayBudget struct {
	mu            sync.Mutex
	incidentLimit int64
	dailyLimit    int64
	incidentUsed  int64
	buckets       []byteBucket
	now           func() time.Time
}

func NewReplayBudget(incidentLimit, dailyLimit int64) *ReplayBudget {
	return &ReplayBudget{incidentLimit: incidentLimit, dailyLimit: dailyLimit, now: time.Now}
}

func (b *ReplayBudget) Add(bytes int64) error {
	if bytes <= 0 {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now().UTC()
	b.prune(now)
	b.incidentUsed += bytes
	minute := now.Truncate(time.Minute)
	if len(b.buckets) > 0 && b.buckets[len(b.buckets)-1].minute.Equal(minute) {
		b.buckets[len(b.buckets)-1].bytes += bytes
	} else {
		b.buckets = append(b.buckets, byteBucket{minute: minute, bytes: bytes})
	}
	if b.incidentUsed > b.incidentLimit {
		return ErrIncidentBudgetExceeded
	}
	if b.dailyUsedLocked() > b.dailyLimit {
		return ErrDailyBudgetExceeded
	}
	return nil
}

func (b *ReplayBudget) Seed(incidentUsed int64, durable []ReplayUsageBucket) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.incidentUsed = incidentUsed
	b.buckets = b.buckets[:0]
	for _, bucket := range durable {
		if bucket.Bytes > 0 {
			b.buckets = append(b.buckets, byteBucket{minute: bucket.StartedAt.UTC(), bytes: bucket.Bytes})
		}
	}
	b.prune(b.now().UTC())
}

func (b *ReplayBudget) IncidentUsed() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.incidentUsed
}

func (b *ReplayBudget) ResetIncident() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.incidentUsed = 0
}

func (b *ReplayBudget) WaitForDailyCapacity() time.Duration {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now().UTC()
	b.prune(now)
	if b.dailyUsedLocked() <= b.dailyLimit || len(b.buckets) == 0 {
		return 0
	}
	wait := b.buckets[0].minute.Add(24 * time.Hour).Sub(now)
	if wait < time.Minute {
		return time.Minute
	}
	return wait
}

func (b *ReplayBudget) prune(now time.Time) {
	cutoff := now.Add(-24 * time.Hour)
	index := 0
	for index < len(b.buckets) && !b.buckets[index].minute.After(cutoff) {
		index++
	}
	if index > 0 {
		b.buckets = append([]byteBucket(nil), b.buckets[index:]...)
	}
}

func (b *ReplayBudget) dailyUsedLocked() int64 {
	var total int64
	for _, bucket := range b.buckets {
		total += bucket.bytes
	}
	return total
}

type BudgetTransport struct {
	Base        http.RoundTripper
	Budget      *ReplayBudget
	RecordUsage func(context.Context, int64) error
	Evidence    *TransportEvidence
}

func (t BudgetTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}
	if !isArchiveRequest(request.URL.Path) {
		return base.RoundTrip(request)
	}
	if wait := t.Budget.WaitForDailyCapacity(); wait > 0 {
		return nil, fmt.Errorf("%w; retry in %s", ErrDailyBudgetExceeded, wait.Round(time.Second))
	}
	if t.Evidence != nil {
		t.Evidence.ObserveRequest(request)
	}
	response, err := base.RoundTrip(request)
	if err != nil {
		return nil, err
	}
	if t.Evidence != nil {
		t.Evidence.ObserveResponse(response)
	}
	response.Body = &budgetBody{
		ReadCloser: response.Body, budget: t.Budget, context: request.Context(), recordUsage: t.RecordUsage,
	}
	return response, nil
}

func isArchiveRequest(path string) bool {
	return strings.HasSuffix(path, "/network.bsky.jetstream.planSnapshot") ||
		strings.HasSuffix(path, "/network.bsky.jetstream.getSegment") ||
		strings.HasSuffix(path, "/network.bsky.jetstream.getBlock")
}

type budgetBody struct {
	io.ReadCloser
	budget      *ReplayBudget
	context     context.Context
	recordUsage func(context.Context, int64) error
	pending     int64
}

const usageFlushBytes int64 = 8 << 20

func (b *budgetBody) Read(buffer []byte) (int, error) {
	n, err := b.ReadCloser.Read(buffer)
	b.pending += int64(n)
	if budgetErr := b.budget.Add(int64(n)); budgetErr != nil {
		if recordErr := b.flush(); recordErr != nil {
			return n, recordErr
		}
		if n > 0 {
			return n, budgetErr
		}
		return 0, budgetErr
	}
	if b.pending >= usageFlushBytes || errors.Is(err, io.EOF) {
		if recordErr := b.flush(); recordErr != nil {
			return n, recordErr
		}
	}
	return n, err
}

func (b *budgetBody) Close() error {
	flushErr := b.flush()
	closeErr := b.ReadCloser.Close()
	return errors.Join(flushErr, closeErr)
}

func (b *budgetBody) flush() error {
	if b.pending <= 0 || b.recordUsage == nil {
		b.pending = 0
		return nil
	}
	bytes := b.pending
	b.pending = 0
	flushContext, cancel := context.WithTimeout(context.WithoutCancel(b.context), 5*time.Second)
	defer cancel()
	return b.recordUsage(flushContext, bytes)
}

type EvidenceSnapshot struct {
	RetryCount       int
	RangeResumeCount int
	ETag             string
}

type TransportEvidence struct {
	retries      atomic.Int64
	rangeResumes atomic.Int64
	mu           sync.Mutex
	requests     map[string]int
	rangeStarts  map[string]int64
	etag         string
}

func NewTransportEvidence() *TransportEvidence {
	return &TransportEvidence{requests: make(map[string]int), rangeStarts: make(map[string]int64)}
}

func (e *TransportEvidence) Seed(retryCount, rangeResumeCount int, etag string) {
	e.retries.Store(int64(retryCount))
	e.rangeResumes.Store(int64(rangeResumeCount))
	e.mu.Lock()
	e.etag = etag
	e.mu.Unlock()
}

func (e *TransportEvidence) ObserveRequest(request *http.Request) {
	e.mu.Lock()
	defer e.mu.Unlock()
	rangeHeader := request.Header.Get("Range")
	key := request.Method + " " + request.URL.String() + " " + rangeHeader
	if e.requests[key] > 0 {
		e.retries.Add(1)
	}
	e.requests[key]++
	start, end, ok := parseByteRange(rangeHeader)
	if !ok {
		return
	}
	rangeKey := request.URL.String() + "|" + strconv.FormatInt(end, 10)
	if previous, exists := e.rangeStarts[rangeKey]; exists && start > previous {
		e.rangeResumes.Add(1)
	}
	e.rangeStarts[rangeKey] = start
}

func (e *TransportEvidence) ObserveResponse(response *http.Response) {
	if etag := response.Header.Get("ETag"); etag != "" {
		e.mu.Lock()
		e.etag = etag
		e.mu.Unlock()
	}
}

func (e *TransportEvidence) Snapshot() EvidenceSnapshot {
	e.mu.Lock()
	etag := e.etag
	e.mu.Unlock()
	return EvidenceSnapshot{
		RetryCount: int(e.retries.Load()), RangeResumeCount: int(e.rangeResumes.Load()), ETag: etag,
	}
}

func parseByteRange(value string) (int64, int64, bool) {
	if !strings.HasPrefix(value, "bytes=") {
		return 0, 0, false
	}
	parts := strings.Split(strings.TrimPrefix(value, "bytes="), "-")
	if len(parts) != 2 {
		return 0, 0, false
	}
	start, startErr := strconv.ParseInt(parts[0], 10, 64)
	end, endErr := strconv.ParseInt(parts[1], 10, 64)
	return start, end, startErr == nil && endErr == nil && start >= 0 && end >= start
}
