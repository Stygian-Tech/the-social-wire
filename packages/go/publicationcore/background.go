package publicationcore

import (
	"context"
)

func (s *Service) Close() {
	s.bgmu.Lock()
	s.bgclosed = true
	s.cancel()
	s.bgmu.Unlock()
	s.bgwg.Wait()
}
func (s *Service) launch(key string, run func(context.Context)) bool {
	s.bgmu.Lock()
	defer s.bgmu.Unlock()
	if s.bgclosed || s.bgkeys[key] {
		return false
	}
	select {
	case s.bgslots <- struct{}{}:
	default:
		return false
	}
	s.bgkeys[key] = true
	s.bgwg.Add(1)
	go func() {
		defer s.bgwg.Done()
		defer func() { s.bgmu.Lock(); delete(s.bgkeys, key); s.bgmu.Unlock(); <-s.bgslots }()
		run(s.background)
	}()
	return true
}
