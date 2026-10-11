package analytics

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/analyticscore"
	"sync"
	"time"
)

type limitState struct {
	until time.Time
	count int
}
type Limits struct {
	mu      sync.Mutex
	entries map[string]limitState
}

// Bounded process-local admission complements the durable daily observer budget.
func (l *Limits) Allow(key string, now time.Time, maximum int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.entries == nil {
		l.entries = map[string]limitState{}
	}
	for k, v := range l.entries {
		if !now.Before(v.until) {
			delete(l.entries, k)
		}
	}
	v := l.entries[key]
	if v.until.IsZero() {
		if len(l.entries) >= 10000 {
			return false
		}
		v.until = now.Add(time.Minute)
	}
	if v.count >= maximum {
		return false
	}
	v.count++
	l.entries[key] = v
	return true
}

type ownership struct{ until time.Time }
type CachedProvider struct {
	Base     Content
	mu       sync.Mutex
	cache    map[string]ownership
	inflight map[string]chan struct{}
}

func (p *CachedProvider) Inventory(ctx context.Context, did string, at time.Time) ([]analyticscore.Item, bool, error) {
	return p.Base.Inventory(ctx, did, at)
}

// Only successful public canonical reads are cached; a changed/deleted record expires in five minutes.
func (p *CachedProvider) Validate(ctx context.Context, uri string) error {
	for {
		p.mu.Lock()
		if time.Now().Before(p.cache[uri].until) {
			p.mu.Unlock()
			return nil
		}
		if ch := p.inflight[uri]; ch != nil {
			p.mu.Unlock()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-ch:
				continue
			}
		}
		if len(p.inflight) >= 1000 {
			p.mu.Unlock()
			return errors.New("canonical validation busy")
		}
		if p.inflight == nil {
			p.inflight = map[string]chan struct{}{}
		}
		ch := make(chan struct{})
		p.inflight[uri] = ch
		p.mu.Unlock()
		e := p.Base.Validate(ctx, uri)
		p.mu.Lock()
		delete(p.inflight, uri)
		if e == nil {
			if p.cache == nil {
				p.cache = map[string]ownership{}
			}
			for k, v := range p.cache {
				if time.Now().After(v.until) {
					delete(p.cache, k)
				}
			}
			if len(p.cache) < 10000 {
				p.cache[uri] = ownership{time.Now().Add(5 * time.Minute)}
			}
		}
		close(ch)
		p.mu.Unlock()
		return e
	}
}
