package wireworkercore

// Serializes in-process ranking reservations with unique completion tokens. Successful
// cadence is measured from cycle start, failures retry after one minute and clear
// readiness, and stale completions cannot release a newer reservation. Distributed
// ownership still requires role leases.

import (
	"sync"
	"time"
)

// Reservation returns either a unique work token or the wait before another scheduling
// attempt.
type Reservation struct {
	Token string
	Wait  time.Duration
}

// RankingScheduler serializes local cycles and tracks freshness of the last successful
// cycle start.
type RankingScheduler struct {
	mu                                     sync.Mutex
	nextAttemptAt, lastSuccessfulStartedAt *time.Time
	activeToken                            string
	activeStartedAt                        time.Time
}

// Reserve returns a token only when no cycle is active and the next attempt is due.
func (rankingScheduler *RankingScheduler) Reserve(now time.Time) (Reservation, error) {
	rankingScheduler.mu.Lock()
	defer rankingScheduler.mu.Unlock()
	if rankingScheduler.activeToken != "" {
		return Reservation{Wait: time.Second}, nil
	}
	if rankingScheduler.nextAttemptAt != nil && now.Before(*rankingScheduler.nextAttemptAt) {
		wait := rankingScheduler.nextAttemptAt.Sub(now)
		return Reservation{Wait: max(time.Millisecond, ((wait+time.Millisecond-1)/time.Millisecond)*time.Millisecond)}, nil
	}
	token, err := newGenerationID()
	if err != nil {
		return Reservation{}, err
	}
	rankingScheduler.activeToken = token
	rankingScheduler.activeStartedAt = now
	return Reservation{Token: token}, nil
}

// Succeeded accepts only the active token and schedules cadence from its start time,
// including time already spent working.
func (rankingScheduler *RankingScheduler) Succeeded(token string, now time.Time, interval time.Duration) {
	rankingScheduler.mu.Lock()
	defer rankingScheduler.mu.Unlock()
	if rankingScheduler.activeToken == "" || rankingScheduler.activeToken != token {
		return
	}
	remaining := max(0, interval-max(0, now.Sub(rankingScheduler.activeStartedAt)))
	next := now.Add(remaining)
	rankingScheduler.nextAttemptAt = &next
	started := rankingScheduler.activeStartedAt
	rankingScheduler.lastSuccessfulStartedAt = &started
	rankingScheduler.activeToken = ""
}

// Failed accepts only the active token, clears readiness, and schedules a one-minute
// retry.
func (rankingScheduler *RankingScheduler) Failed(token string, now time.Time) {
	rankingScheduler.mu.Lock()
	defer rankingScheduler.mu.Unlock()
	if rankingScheduler.activeToken == "" || rankingScheduler.activeToken != token {
		return
	}
	next := now.Add(time.Minute)
	rankingScheduler.nextAttemptAt = &next
	rankingScheduler.lastSuccessfulStartedAt = nil
	rankingScheduler.activeToken = ""
}

// IsGenerationReady requires a successful start instant no later than now and within
// maximumAge.
func (rankingScheduler *RankingScheduler) IsGenerationReady(now time.Time, maximumAge time.Duration) bool {
	rankingScheduler.mu.Lock()
	defer rankingScheduler.mu.Unlock()
	return rankingScheduler.lastSuccessfulStartedAt != nil && !now.Before(*rankingScheduler.lastSuccessfulStartedAt) && now.Sub(*rankingScheduler.lastSuccessfulStartedAt) <= maximumAge
}
