package edge

import (
	"sync"
	"time"
)

type ReplayGuard struct {
	mu       sync.Mutex
	capacity int
	accepted map[string]time.Time
}

func NewReplayGuard(capacity int) *ReplayGuard {
	return &ReplayGuard{capacity: max(1, capacity), accepted: map[string]time.Time{}}
}
func (g *ReplayGuard) Consume(nonce string, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	cutoff := now.Add(-time.Minute)
	for value, at := range g.accepted {
		if at.Before(cutoff) {
			delete(g.accepted, value)
		}
	}
	if _, exists := g.accepted[nonce]; exists || len(g.accepted) >= g.capacity {
		return false
	}
	g.accepted[nonce] = now
	return true
}
