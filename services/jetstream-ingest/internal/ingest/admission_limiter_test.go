package ingest

import (
	"testing"
	"time"
)

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
