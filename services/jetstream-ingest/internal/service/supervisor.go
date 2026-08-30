package service

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

type SupervisedLane struct {
	Name string
	Run  func(context.Context) error
}

// Supervisor keeps lane lifecycle failures isolated. Each lane owns its database handle, lease,
// runner and health state; a failed lane is restarted without cancelling healthy siblings.
type Supervisor struct {
	Lanes           []SupervisedLane
	RestartMinDelay time.Duration
	RestartMaxDelay time.Duration
	Logger          *slog.Logger
}

func (s Supervisor) Run(ctx context.Context) {
	minimumDelay := s.RestartMinDelay
	if minimumDelay <= 0 {
		minimumDelay = time.Second
	}
	maximumDelay := s.RestartMaxDelay
	if maximumDelay < minimumDelay {
		maximumDelay = 30 * time.Second
	}
	var group sync.WaitGroup
	for _, lane := range s.Lanes {
		lane := lane
		group.Add(1)
		go func() {
			defer group.Done()
			delay := minimumDelay
			for ctx.Err() == nil {
				err := lane.Run(ctx)
				if ctx.Err() != nil {
					return
				}
				if err != nil && s.Logger != nil {
					s.Logger.Error("ingestion lane stopped; restarting", "lane", lane.Name, "error", err)
				}
				timer := time.NewTimer(delay)
				select {
				case <-ctx.Done():
					if !timer.Stop() {
						<-timer.C
					}
					return
				case <-timer.C:
				}
				delay = min(delay*2, maximumDelay)
			}
		}()
	}
	group.Wait()
}
