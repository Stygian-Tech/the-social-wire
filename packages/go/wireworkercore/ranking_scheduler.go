package wireworkercore

import (
	"sync"
	"time"
)

type Reservation struct {
	Token string
	Wait  time.Duration
}
type RankingScheduler struct {
	mu                                     sync.Mutex
	nextAttemptAt, lastSuccessfulStartedAt *time.Time
	activeToken                            string
	activeStartedAt                        time.Time
}

func (s *RankingScheduler) Reserve(now time.Time) (Reservation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeToken != "" {
		return Reservation{Wait: time.Second}, nil
	}
	if s.nextAttemptAt != nil && now.Before(*s.nextAttemptAt) {
		wait := s.nextAttemptAt.Sub(now)
		return Reservation{Wait: max(time.Millisecond, ((wait+time.Millisecond-1)/time.Millisecond)*time.Millisecond)}, nil
	}
	token, err := newGenerationID()
	if err != nil {
		return Reservation{}, err
	}
	s.activeToken = token
	s.activeStartedAt = now
	return Reservation{Token: token}, nil
}
func (s *RankingScheduler) Succeeded(token string, now time.Time, interval time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeToken == "" || s.activeToken != token {
		return
	}
	remaining := max(0, interval-max(0, now.Sub(s.activeStartedAt)))
	next := now.Add(remaining)
	s.nextAttemptAt = &next
	started := s.activeStartedAt
	s.lastSuccessfulStartedAt = &started
	s.activeToken = ""
}
func (s *RankingScheduler) Failed(token string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeToken == "" || s.activeToken != token {
		return
	}
	next := now.Add(time.Minute)
	s.nextAttemptAt = &next
	s.lastSuccessfulStartedAt = nil
	s.activeToken = ""
}
func (s *RankingScheduler) IsGenerationReady(now time.Time, maximumAge time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastSuccessfulStartedAt != nil && !now.Before(*s.lastSuccessfulStartedAt) && now.Sub(*s.lastSuccessfulStartedAt) <= maximumAge
}
