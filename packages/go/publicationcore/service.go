package publicationcore

import (
	"context"
	"database/sql"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"sync"
	"time"
)

type Service struct {
	Enroller    *Enroller
	Lists       func(context.Context, gatewaycore.AuthContext) (any, error)
	background  context.Context
	cancel      context.CancelFunc
	bgmu        sync.Mutex
	bgwg        sync.WaitGroup
	bgclosed    bool
	bgkeys      map[string]bool
	bgslots     chan struct{}
	Cache       *CacheStore
	DB          *sql.DB
	Repo        Repository
	Client      *http.Client
	Now         func() time.Time
	mu          sync.Mutex
	discoveries map[string]discoveryEntry
	scopes      map[string]scopeEntry
	rows        map[string]map[string]SidebarRow
}
type discoveryEntry struct {
	value   DiscoveryContext
	expires time.Time
}
type scopeEntry struct {
	value   AppViewScope
	expires time.Time
}

func NewService(db *sql.DB, repo Repository, client *http.Client) *Service {
	if client == nil {
		client = gatewaycore.NewPublicHTTPClient(nil)
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &Service{background: ctx, cancel: cancel, bgkeys: map[string]bool{}, bgslots: make(chan struct{}, 64), DB: db, Repo: repo, Client: client, Now: time.Now, discoveries: map[string]discoveryEntry{}, scopes: map[string]scopeEntry{}, rows: map[string]map[string]SidebarRow{}}
}
func (s *Service) Scope(ctx context.Context, id, author string) AppViewScope {
	key := NormalizeATRepoParam(id)
	s.mu.Lock()
	hit, ok := s.scopes[key]
	s.mu.Unlock()
	at := s.Now()
	if ok && hit.expires.After(at) {
		return hit.value
	}
	scope := BuildScope(ctx, s.Repo, id, author)
	s.mu.Lock()
	s.scopes[key] = scopeEntry{scope, at.Add(5 * time.Minute)}
	s.mu.Unlock()
	return scope
}
func (s *Service) ResolveScope(ctx context.Context, auth gatewaycore.AuthContext, id string) (appviewcore.PublicationScope, error) {
	id = NormalizeATRepoParam(id)
	if scope, e := (ProjectionStore{DB: s.DB}).Scope(ctx, auth.DID, id); e != nil {
		return appviewcore.PublicationScope{}, e
	} else if scope != nil {
		return scope.ReadScope(id), nil
	}
	scope := s.Scope(ctx, id, RepoDID(id))
	return scope.ReadScope(id), nil
}
func (s *Service) ResolveIDs(ctx context.Context, auth gatewaycore.AuthContext, ids []string) ([]appviewcore.PublicationScope, error) {
	out := []appviewcore.PublicationScope{}
	for _, id := range ids {
		scope, e := s.ResolveScope(ctx, auth, id)
		if e != nil {
			return nil, e
		}
		out = append(out, scope)
	}
	return out, nil
}
func (s *Service) Discover(ctx context.Context, viewer string, includeFollows bool) (DiscoveryContext, error) {
	s.mu.Lock()
	cached := s.discoveries[viewer]
	s.mu.Unlock()
	prior := []DiscoveredRow{}
	if cached.expires.After(s.Now()) {
		prior = cached.value.Following
	}
	discovery, e := Discover(ctx, s.Repo, s.Client, viewer, includeFollows, prior, s.Now())
	if e == nil {
		s.mu.Lock()
		s.discoveries[viewer] = discoveryEntry{discovery, s.Now().Add(10 * time.Minute)}
		s.mu.Unlock()
	}
	return discovery, e
}
func (s *Service) Sidebar(ctx context.Context, auth gatewaycore.AuthContext, phase string) (Sidebar, error) {
	var discovery DiscoveryContext
	var e error
	if phase == "folderPublications" {
		s.mu.Lock()
		cached := s.discoveries[auth.DID]
		s.mu.Unlock()
		if cached.expires.After(s.Now()) {
			discovery = cached.value
		} else {
			discovery, e = s.Discover(ctx, auth.DID, true)
		}
	} else {
		discovery, e = s.Discover(ctx, auth.DID, true)
	}
	if e != nil {
		return Sidebar{}, e
	}
	return s.BuildSidebar(ctx, discovery, phase)
}
func (s *Service) Priority(ctx context.Context, auth gatewaycore.AuthContext, refresh bool) (Sidebar, DiscoveryContext, error) {
	if refresh {
		s.mu.Lock()
		for key := range s.rows[auth.DID] {
			delete(s.scopes, NormalizeATRepoParam(key))
		}
		delete(s.rows, auth.DID)
		s.mu.Unlock()
	}
	var discovery DiscoveryContext
	var e error
	s.mu.Lock()
	cached := s.discoveries[auth.DID]
	s.mu.Unlock()
	if !refresh && cached.expires.After(s.Now()) {
		discovery = cached.value
	} else {
		discovery, e = s.Discover(ctx, auth.DID, false)
	}
	if e != nil {
		return Sidebar{}, discovery, e
	}
	sidebar, e := s.BuildSidebar(ctx, discovery, "priority")
	return sidebar, discovery, e
}
func (s *Service) Counters(ctx context.Context, viewer string, rows []SidebarRow, refresh bool) (CounterSnapshot, error) {
	scopes := []appviewcore.PublicationScope{}
	for _, row := range rows {
		scopes = append(scopes, row.AppViewScope.ReadScope(row.PublicationID))
	}
	store := CounterStore{DB: s.DB}
	if refresh {
		return store.Refresh(ctx, viewer, scopes, s.Now())
	}
	return store.Snapshot(ctx, viewer, scopes, s.Now())
}
func (s *Service) Refresh(ctx context.Context, auth gatewaycore.AuthContext) (Sidebar, error) {
	if s.Cache != nil {
		_ = s.Cache.InvalidateSidebar(ctx, auth.DID)
	}
	sidebar, _, e := s.Priority(ctx, auth, true)
	if e == nil {
		s.launch("sidebar:"+auth.DID, func(work context.Context) { s.rebuild(work, auth) })
	}
	return sidebar, e
}
func (s *Service) SidebarRows(viewer string, ids []string) []SidebarRow {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []SidebarRow{}
	for _, id := range ids {
		for _, key := range LookupKeys(id) {
			if row, ok := s.rows[viewer][key]; ok {
				out = append(out, row)
				break
			}
		}
	}
	return out
}
