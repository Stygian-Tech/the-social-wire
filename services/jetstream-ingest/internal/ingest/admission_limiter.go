package ingest

import (
	"errors"
	"math"
	"sync"
	"time"
)

// AdmissionRateLimiter is a shared token bucket. Reserve returns the
// delay required before a bounded staging transaction may be committed.
type AdmissionRateLimiter struct {
	mu            sync.Mutex
	ratePerSecond float64
	burst         int
	tokens        float64
	updatedAt     time.Time
}

func NewAdmissionRateLimiter(ratePerSecond float64, burst int, now time.Time) (*AdmissionRateLimiter, error) {
	if ratePerSecond <= 0 || math.IsNaN(ratePerSecond) || math.IsInf(ratePerSecond, 0) {
		return nil, errors.New("admission rate must be finite and positive")
	}
	if burst < 1 {
		return nil, errors.New("admission burst must be positive")
	}
	return &AdmissionRateLimiter{
		ratePerSecond: ratePerSecond,
		burst:         burst,
		tokens:        float64(burst),
		updatedAt:     now,
	}, nil
}

func (l *AdmissionRateLimiter) Reserve(count int, now time.Time) (time.Duration, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if count < 0 || count > l.burst {
		return 0, errors.New("admission reservation exceeds configured burst")
	}
	if count == 0 {
		return 0, nil
	}
	if now.After(l.updatedAt) {
		elapsed := now.Sub(l.updatedAt).Seconds()
		l.tokens = math.Min(float64(l.burst), l.tokens+elapsed*l.ratePerSecond)
		l.updatedAt = now
	}
	if l.tokens >= float64(count) {
		l.tokens -= float64(count)
		return 0, nil
	}
	missing := float64(count) - l.tokens
	waitNanoseconds := math.Ceil(missing / l.ratePerSecond * float64(time.Second))
	wait := time.Duration(waitNanoseconds)
	if l.updatedAt.After(now) {
		wait += l.updatedAt.Sub(now)
	}
	l.tokens = 0
	l.updatedAt = now.Add(wait)
	return wait, nil
}
