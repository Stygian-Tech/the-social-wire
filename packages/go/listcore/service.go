package listcore

import (
	"context"
	"sync"
	"time"
)

type cachedResponse struct {
	response Response
	expires  time.Time
}
type listFlight struct {
	done     chan struct{}
	response Response
	err      error
	revision uint64
}

// Service coalesces viewer loads and fences refreshes so an older PDS read
// cannot replace newer list membership. Preparation is injected by the host.
type Service struct {
	Reader     Reader
	Prepare    func(context.Context, string, List)
	Enrich     func(context.Context, string, List) List
	Invalidate func(string)
	mu         sync.Mutex
	cache      map[string]cachedResponse
	loads      map[string]*listFlight
	revisions  map[string]uint64
}

func (s *Service) Lists(ctx context.Context, viewer string, refresh bool) (Response, error) {
	s.mu.Lock()
	if s.cache == nil {
		s.cache = map[string]cachedResponse{}
		s.loads = map[string]*listFlight{}
		s.revisions = map[string]uint64{}
	}
	if !refresh {
		if cached, ok := s.cache[viewer]; ok && cached.expires.After(time.Now()) {
			response := cloneResponse(cached.response)
			s.mu.Unlock()
			return s.enriched(ctx, viewer, response), nil
		}
		if flight := s.loads[viewer]; flight != nil {
			s.mu.Unlock()
			select {
			case <-ctx.Done():
				return Response{}, ctx.Err()
			case <-flight.done:
			}
			if flight.err != nil {
				return Response{}, flight.err
			}
			return s.enriched(ctx, viewer, cloneResponse(flight.response)), nil
		}
	}
	s.revisions[viewer]++
	flight := &listFlight{done: make(chan struct{}), revision: s.revisions[viewer]}
	s.loads[viewer] = flight
	s.mu.Unlock()
	if refresh && s.Invalidate != nil {
		s.Invalidate(viewer)
	}
	response, err := Load(ctx, s.Reader, viewer)
	s.mu.Lock()
	flight.response, flight.err = cloneResponse(response), err
	current := s.revisions[viewer] == flight.revision
	if current {
		delete(s.loads, viewer)
		if err == nil {
			s.cache[viewer] = cachedResponse{cloneResponse(response), time.Now().Add(time.Minute)}
		}
	}
	if len(s.cache) > 200 {
		now := time.Now()
		for key, cached := range s.cache {
			if !cached.expires.After(now) {
				delete(s.cache, key)
			}
		}
		for len(s.cache) > 200 {
			oldest := ""
			var expires time.Time
			for key, cached := range s.cache {
				if oldest == "" || cached.expires.Before(expires) {
					oldest, expires = key, cached.expires
				}
			}
			delete(s.cache, oldest)
		}
	}
	close(flight.done)
	s.mu.Unlock()
	if err != nil {
		return Response{}, err
	}
	if current && s.Prepare != nil {
		for _, list := range response.Lists {
			s.Prepare(ctx, viewer, cloneList(list))
		}
	}
	return s.enriched(ctx, viewer, response), nil
}

func (s *Service) Search(ctx context.Context, creator, viewer string) (Response, error) {
	lists, err := s.Lists(ctx, viewer, false)
	if err != nil {
		return Response{}, err
	}
	saved := map[string]bool{}
	for _, list := range lists.Lists {
		if list.Saved {
			saved[list.URI] = true
		}
	}
	response, err := Search(ctx, s.Reader, creator, viewer, saved)
	if err != nil {
		return Response{}, err
	}
	return s.enriched(ctx, viewer, response), nil
}
func (s *Service) Resolve(ctx context.Context, input, viewer string) (*List, error) {
	list, err := Resolve(ctx, s.Reader, input, viewer, false)
	if err != nil {
		return nil, err
	}
	if s.Prepare != nil {
		s.Prepare(ctx, viewer, cloneList(*list))
	}
	if s.Enrich != nil {
		value := s.Enrich(ctx, viewer, *list)
		list = &value
	}
	return list, nil
}
func (s *Service) enriched(ctx context.Context, viewer string, response Response) Response {
	response = cloneResponse(response)
	if s.Enrich != nil {
		for i, list := range response.Lists {
			response.Lists[i] = s.Enrich(ctx, viewer, list)
		}
	}
	return response
}
func cloneResponse(response Response) Response {
	if response.Lists != nil {
		lists := make([]List, len(response.Lists))
		for i, list := range response.Lists {
			lists[i] = cloneList(list)
		}
		response.Lists = lists
	}
	if response.CreatorDID != nil {
		did := *response.CreatorDID
		response.CreatorDID = &did
	}
	return response
}
func cloneList(list List) List {
	list.Publications = append([]string{}, list.Publications...)
	list.Users = append([]string{}, list.Users...)
	if list.Description != nil {
		value := *list.Description
		list.Description = &value
	}
	if list.PublicationDetails != nil {
		details := append([]Publication{}, (*list.PublicationDetails)...)
		for i := range details {
			if details[i].AuthorHandle != nil {
				value := *details[i].AuthorHandle
				details[i].AuthorHandle = &value
			}
			if details[i].IconURL != nil {
				value := *details[i].IconURL
				details[i].IconURL = &value
			}
			if details[i].AvatarURL != nil {
				value := *details[i].AvatarURL
				details[i].AvatarURL = &value
			}
		}
		list.PublicationDetails = &details
	}
	return list
}
