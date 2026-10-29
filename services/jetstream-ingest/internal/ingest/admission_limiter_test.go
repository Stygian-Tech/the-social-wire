package ingest

import (
	"sort"
	"sync"
	"testing"
	"time"
)

func TestSharedAdmissionLimiterConcurrentReservationsQueueFutureDebt(t *testing.T) {
	now := time.Unix(1700000000, 0)
	limiter, err := NewAdmissionRateLimiter(2, 1, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := limiter.Reserve(1, now); err != nil {
		t.Fatal(err)
	}
	const workers = 8
	waits := make([]time.Duration, workers)
	errs := make([]error, workers)
	var group sync.WaitGroup
	for index := range workers {
		group.Add(1)
		go func() { defer group.Done(); waits[index], errs[index] = limiter.Reserve(1, now) }()
	}
	group.Wait()
	sort.Slice(waits, func(i, j int) bool { return waits[i] < waits[j] })
	for index, wait := range waits {
		if errs[index] != nil {
			t.Fatal(errs[index])
		}
		want := time.Duration(index+1) * 500 * time.Millisecond
		if wait != want {
			t.Fatalf("concurrent reservation[%d]=%s want %s; future capacity oversubscribed", index, wait, want)
		}
	}
	if wait, err := limiter.Reserve(1, now.Add(2*time.Second)); err != nil || wait != 2500*time.Millisecond {
		t.Fatalf("existing future debt lost: wait=%s err=%v", wait, err)
	}
}

func TestAdmissionRateLimiterBoundsBurstAndRefill(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	limiter, err := NewAdmissionRateLimiter(2.5, 2, now)
	if err != nil {
		t.Fatal(err)
	}
	if wait, err := limiter.Reserve(2, now); err != nil || wait != 0 {
		t.Fatalf("initial burst wait=%s error=%v", wait, err)
	}
	wait, err := limiter.Reserve(1, now)
	if err != nil {
		t.Fatal(err)
	}
	if wait != 400*time.Millisecond {
		t.Fatalf("refill wait=%s, want 400ms", wait)
	}
	if wait, err := limiter.Reserve(1, now.Add(800*time.Millisecond)); err != nil || wait != 0 {
		t.Fatalf("post-refill wait=%s error=%v", wait, err)
	}
}

func TestAdmissionRateLimiterRejectsUnsafeConfigurationAndOversizedReservation(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	for _, rate := range []float64{0, -1} {
		if _, err := NewAdmissionRateLimiter(rate, 1, now); err == nil {
			t.Fatalf("accepted rate %v", rate)
		}
	}
	if _, err := NewAdmissionRateLimiter(1, 0, now); err == nil {
		t.Fatal("accepted zero burst")
	}
	limiter, err := NewAdmissionRateLimiter(1, 2, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := limiter.Reserve(3, now); err == nil {
		t.Fatal("accepted reservation larger than burst")
	}
}
