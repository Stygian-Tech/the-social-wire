package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"time"
)

type InboxRepository struct{ Environment, SourceGeneration, RepoDID string }

func nullString(value string) sql.NullString { return sql.NullString{String: value, Valid: true} }

type InboxEvent struct {
	Repository                        InboxRepository
	Sequence                          int64
	SourceHost, CursorKind, EventKind string
	Collection, Operation, RecordKey  sql.NullString
	PayloadJSON                       string
	EventTime                         time.Time
	LeaseToken                        string
	AttemptCount                      int
}

func (e InboxEvent) SourceURI() string {
	if !e.Collection.Valid || !e.RecordKey.Valid {
		return ""
	}
	return "at://" + e.Repository.RepoDID + "/" + e.Collection.String + "/" + e.RecordKey.String
}
func (e InboxEvent) PassiveDelete() bool {
	return e.Operation.String == "delete" && (e.Collection.String == "app.bsky.feed.like" || e.Collection.String == "app.bsky.feed.repost")
}

type InboxOutcome string

const (
	InboxApplied   InboxOutcome = "applied"
	InboxDeferred  InboxOutcome = "deferred"
	InboxTerminal  InboxOutcome = "terminal"
	InboxRetry     InboxOutcome = "retry"
	InboxLeaseLost InboxOutcome = "lease_lost"
)

func (o InboxOutcome) Continues() bool {
	return o == InboxApplied || o == InboxDeferred || o == InboxTerminal
}

type InboxWorkBatch struct {
	Events         []InboxEvent
	PassiveApplied int
	NextRepository *InboxRepository
}
type InboxProcessor interface {
	ClaimWork(context.Context, time.Time, int, *InboxRepository) (InboxWorkBatch, error)
	ClaimNext(context.Context, InboxRepository, time.Time) (*InboxEvent, error)
	ApplyClaimed(context.Context, InboxEvent, time.Time) (InboxOutcome, error)
}

// DrainEvidence separates a healthy admission query from stale individual operations.
// A single slow event cannot hide behind successful admissions from other repositories.
type DrainEvidence struct {
	mu                       sync.Mutex
	lastSuccess, timeStarted time.Time
	failed                   bool
	operations               map[uint64]time.Time
	nextID                   uint64
}

func (s *DrainEvidence) admissionStarted(at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.timeStarted = at
}
func (s *DrainEvidence) admissionFinished(at time.Time, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.timeStarted = time.Time{}
	s.failed = err != nil
	if err == nil {
		s.lastSuccess = at
	}
}
func (s *DrainEvidence) operationStarted(at time.Time) uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nextID++
	if s.operations == nil {
		s.operations = map[uint64]time.Time{}
	}
	s.operations[s.nextID] = at
	return s.nextID
}
func (s *DrainEvidence) operationFinished(id uint64, at time.Time, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.operations, id)
	if err != nil {
		s.failed = true
	} else {
		s.lastSuccess = at
	}
}
func (s *DrainEvidence) Ready(at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed || s.lastSuccess.IsZero() || at.Sub(s.lastSuccess) > 60*time.Second {
		return errors.New("Wire drain lacks recent successful evidence")
	}
	if !s.timeStarted.IsZero() && at.Sub(s.timeStarted) > 180*time.Second {
		return errors.New("Wire admission is stale")
	}
	for _, started := range s.operations {
		if at.Sub(started) > 180*time.Second {
			return errors.New("Wire event application is stale")
		}
	}
	return nil
}

type DrainConfig struct {
	Concurrency, MaximumEventsPerTurn                 int
	MaximumTurn, Idle, InitialBackoff, MaximumBackoff time.Duration
}

func DefaultDrainConfig() DrainConfig {
	return DrainConfig{16, 16, time.Second, 250 * time.Millisecond, time.Second, 30 * time.Second}
}

type DrainRuntime struct {
	Processor InboxProcessor
	Evidence  *DrainEvidence
	Config    DrainConfig
	Now       func() time.Time
	OnFailure func(error)
}

func waitContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (r DrainRuntime) Run(ctx context.Context) error {
	if r.Processor == nil || r.Evidence == nil {
		return errors.New("Wire drain dependencies are required")
	}
	if r.Now == nil {
		r.Now = time.Now
	}
	c := r.Config
	c.Concurrency = max(1, min(c.Concurrency, 64))
	c.MaximumEventsPerTurn = max(1, min(c.MaximumEventsPerTurn, 64))
	c.Idle = max(c.Idle, time.Millisecond)
	c.InitialBackoff = max(c.InitialBackoff, time.Millisecond)
	c.MaximumBackoff = max(c.MaximumBackoff, c.InitialBackoff)
	ctx, cancel := context.WithCancel(ctx)
	var workers sync.WaitGroup
	defer func() { cancel(); workers.Wait() }()
	finished := make(chan struct{}, c.Concurrency)
	active := 0
	var cursor *InboxRepository
	backoff := c.InitialBackoff
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if active < c.Concurrency {
			at := r.Now()
			r.Evidence.admissionStarted(at)
			batch, err := r.Processor.ClaimWork(ctx, at, c.Concurrency-active, cursor)
			r.Evidence.admissionFinished(r.Now(), err)
			if err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				if r.OnFailure != nil {
					r.OnFailure(err)
				}
				if err = waitContext(ctx, backoff); err != nil {
					return err
				}
				backoff = min(backoff*2, c.MaximumBackoff)
			} else {
				if len(batch.Events) > c.Concurrency-active {
					return errors.New("Wire claim exceeded execution-slot ceiling")
				}
				cursor = batch.NextRepository
				backoff = c.InitialBackoff
				for _, event := range batch.Events {
					active++
					workers.Go(func() { r.runTurn(ctx, event, c); finished <- struct{}{} })
				}
			}
		}
		// One timer keeps spare capacity available while existing turns wait on dependencies.
		timer := time.NewTimer(c.Idle)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-finished:
			timer.Stop()
			active--
		case <-timer.C:
		}
	}
}
func (r DrainRuntime) runTurn(ctx context.Context, event InboxEvent, c DrainConfig) {
	started := r.Now()
	for index := 0; index < c.MaximumEventsPerTurn; index++ {
		if ctx.Err() != nil {
			return
		}
		id := r.Evidence.operationStarted(r.Now())
		outcome, err := r.Processor.ApplyClaimed(ctx, event, r.Now())
		r.Evidence.operationFinished(id, r.Now(), err)
		if err != nil {
			if ctx.Err() == nil && r.OnFailure != nil {
				r.OnFailure(err)
			}
			return
		}
		if !outcome.Continues() || event.PassiveDelete() || index+1 >= c.MaximumEventsPerTurn || r.Now().Sub(started) >= c.MaximumTurn {
			return
		}
		if ctx.Err() != nil {
			return
		}
		id = r.Evidence.operationStarted(r.Now())
		next, err := r.Processor.ClaimNext(ctx, event.Repository, r.Now())
		r.Evidence.operationFinished(id, r.Now(), err)
		if err != nil {
			if ctx.Err() == nil && r.OnFailure != nil {
				r.OnFailure(err)
			}
			return
		}
		if next == nil {
			return
		}
		event = *next
	}
}
