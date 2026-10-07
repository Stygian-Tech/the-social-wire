package indexingworkercore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"sync"
	"time"
)

type LaneName string

const (
	AppView LaneName = "appview"
	Wire    LaneName = "wire"
)

type Phase string

const (
	Starting   Phase = "starting"
	Running    Phase = "running"
	Standby    Phase = "standby"
	Restarting Phase = "restarting"
	Stopping   Phase = "stopping"
)

var laneNames = []LaneName{AppView, Wire}

type State struct {
	mu       sync.RWMutex
	phases   map[LaneName]Phase
	stopping map[LaneName]time.Time
	control  map[LaneName]time.Time
}

func NewState() *State {
	return &State{phases: map[LaneName]Phase{}, stopping: map[LaneName]time.Time{}, control: map[LaneName]time.Time{}}
}
func (s *State) setLocked(lane LaneName, phase Phase, at time.Time) {
	s.phases[lane] = phase
	if phase == Stopping {
		if _, ok := s.stopping[lane]; !ok {
			s.stopping[lane] = at
		}
	} else {
		delete(s.stopping, lane)
	}
}
func (s *State) Set(lane LaneName, phase Phase, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.setLocked(lane, phase, at)
}
func (s *State) Record(lane LaneName, event operationscore.LeaseEvent, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch event.Phase {
	case "acquired":
		s.control[lane] = at
		s.setLocked(lane, Starting, at)
	case "standby":
		s.control[lane] = at
		s.setLocked(lane, Standby, at)
	case "renewed", "validated":
		if event.Err == nil {
			s.control[lane] = at
		}
	case "operation_started":
		s.setLocked(lane, Running, at)
	case "operation_stopping", "operation_stopped":
		s.setLocked(lane, Stopping, at)
	case "acquisition_failed", "validation_failed", "released", "release_failed":
		s.setLocked(lane, Restarting, at)
	}
}
func (s *State) Snapshot() map[LaneName]Phase {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := map[LaneName]Phase{}
	for lane, phase := range s.phases {
		result[lane] = phase
	}
	return result
}
func (s *State) HasRecentControlEvidence(now time.Time, maximumAge time.Duration) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, lane := range laneNames {
		at, ok := s.control[lane]
		age := now.Sub(at)
		if !ok || age < 0 || age > maximumAge {
			return false
		}
	}
	return true
}
func (s *State) UnresponsiveLane(now time.Time, grace time.Duration) (LaneName, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, lane := range laneNames {
		if at, ok := s.stopping[lane]; ok && now.Sub(at) >= grace {
			return lane, true
		}
	}
	return "", false
}
