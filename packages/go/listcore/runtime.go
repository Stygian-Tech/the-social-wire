package listcore

import (
	"context"
	"database/sql"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"sync"
	"time"
)

var ErrWarming = errors.New("list projection is warming")
var ErrMissing = errors.New("public list was not found")
var ErrIdentity = errors.New("canonical Standard Reader list AT URI required")

type preparedList struct {
	list    List
	scopes  []appviewcore.PublicationScope
	expires time.Time
}
type siteValue struct {
	url     *string
	expires time.Time
}
type task struct {
	cancel   context.CancelFunc
	revision uint64
}
type Runtime struct {
	Service           *Service
	DB                *sql.DB
	Publication       *publicationcore.Service
	Now               func() time.Time
	ctx               context.Context
	cancel            context.CancelFunc
	mu                sync.Mutex
	closed            bool
	wg                sync.WaitGroup
	limiter           chan struct{}
	enrollmentLimiter chan struct{}
	prepared          map[string]preparedList
	preparing         map[string]task
	revisions         map[string]uint64
	missing           map[string]time.Time
	siteRevision      uint64
	sites             map[string]siteValue
	details           map[string]Publication
	enrollment        map[string]bool
	enrolled          map[string]time.Time
}

func NewRuntime(db *sql.DB, reader Reader, publication *publicationcore.Service) *Runtime {
	ctx, cancel := context.WithCancel(context.Background())
	r := &Runtime{DB: db, Publication: publication, Now: time.Now, ctx: ctx, cancel: cancel, limiter: make(chan struct{}, 2), enrollmentLimiter: make(chan struct{}, 2), prepared: map[string]preparedList{}, preparing: map[string]task{}, revisions: map[string]uint64{}, missing: map[string]time.Time{}, sites: map[string]siteValue{}, details: map[string]Publication{}, enrollment: map[string]bool{}, enrolled: map[string]time.Time{}}
	r.Service = &Service{Reader: reader, Prepare: r.Prepare, Enrich: r.Enrich, Invalidate: r.Invalidate}
	return r
}
func (r *Runtime) Close() { r.mu.Lock(); r.closed = true; r.cancel(); r.mu.Unlock(); r.wg.Wait() }
func (r *Runtime) Invalidate(viewer string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.siteRevision++
	r.sites = map[string]siteValue{}
	r.details = map[string]Publication{}
	prefix := viewer + "\n"
	for key := range r.prepared {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			delete(r.prepared, key)
		}
	}
	for key := range r.missing {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			delete(r.missing, key)
		}
	}
	for key, t := range r.preparing {
		if len(key) >= len(prefix) && key[:len(prefix)] == prefix {
			r.revisions[key]++
			t.cancel()
			delete(r.preparing, key)
		}
	}
}
func (r *Runtime) Prepare(_ context.Context, viewer string, list List) {
	key := viewer + "\n" + list.URI
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	delete(r.missing, key)
	r.revisions[key]++
	revision := r.revisions[key]
	if prior, ok := r.preparing[key]; ok {
		prior.cancel()
	}
	ctx, cancel := context.WithCancel(r.ctx)
	r.preparing[key] = task{cancel, revision}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer cancel()
		select {
		case r.limiter <- struct{}{}:
		case <-ctx.Done():
			return
		}
		scopes := r.ResolvedScopes(ctx, list, viewer)
		<-r.limiter
		r.mu.Lock()
		defer r.mu.Unlock()
		if ctx.Err() != nil || r.revisions[key] != revision {
			return
		}
		r.prepared[key] = preparedList{cloneList(list), scopes, r.Now().Add(time.Minute)}
		delete(r.preparing, key)
		r.trimPrepared()
	}()
}
func (r *Runtime) trimPrepared() {
	if len(r.prepared) <= 1000 {
		return
	}
	for key, value := range r.prepared {
		if !value.expires.After(r.Now()) {
			delete(r.prepared, key)
		}
	}
	for len(r.prepared) > 1000 {
		oldest := ""
		var at time.Time
		for key, value := range r.prepared {
			if oldest == "" || value.expires.Before(at) {
				oldest, at = key, value.expires
			}
		}
		delete(r.prepared, oldest)
	}
}
func (r *Runtime) PreparedFeed(input, viewer string) (List, []appviewcore.PublicationScope, error) {
	identity, ok := ParseIdentity(input)
	if !ok {
		return List{}, nil, ErrIdentity
	}
	key := viewer + "\n" + identity.URI()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.missing[key].After(r.Now()) {
		return List{}, nil, ErrMissing
	}
	if hit, ok := r.prepared[key]; ok && hit.expires.After(r.Now()) {
		return cloneList(hit.list), append([]appviewcore.PublicationScope{}, hit.scopes...), nil
	}
	if _, ok := r.preparing[key]; !ok && !r.closed {
		r.revisions[key]++
		revision := r.revisions[key]
		ctx, cancel := context.WithCancel(r.ctx)
		r.preparing[key] = task{cancel, revision}
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			defer cancel()
			list, err := Resolve(ctx, r.Service.Reader, identity.URI(), viewer, false)
			if err == nil {
				r.Prepare(ctx, viewer, *list)
				return
			}
			r.mu.Lock()
			defer r.mu.Unlock()
			if ctx.Err() != nil || r.revisions[key] != revision {
				return
			}
			if errors.Is(err, ErrNotFound) {
				r.missing[key] = r.Now().Add(time.Minute)
			}
			delete(r.preparing, key)
		}()
	}
	return List{}, nil, ErrWarming
}
func (r *Runtime) Feed(ctx context.Context, auth gatewaycore.AuthContext, id, filter, cursor string, limit int, at time.Time) (*appviewcore.FeedPage, error) {
	list, scopes, e := r.PreparedFeed(id, auth.DID)
	if e != nil {
		return nil, e
	}
	fingerprint := Fingerprint(auth.DID, list, filter)
	var raw *string
	if cursor != "" {
		raw = &cursor
	}
	continuation, e := DecodeCursor(raw, fingerprint)
	if e != nil {
		return nil, e
	}
	next := ""
	if continuation != nil {
		next = *continuation
	}
	complete := true
	if cursor == "" {
		complete = r.beginEnrollment(auth, list)
	}
	page, e := (appviewcore.ContentReader{DB: r.DB}).ScopedEntries(ctx, auth.DID, scopes, filter, next, limit, at)
	if e != nil {
		return nil, e
	}
	if len(page.Response.Entries) == 0 && !complete {
		return nil, ErrWarming
	}
	page.Response.Cursor = EncodeCursor(page.Response.Cursor, fingerprint)
	page.MembershipUpdatedAt = r.Now()
	return &page, nil
}
func (r *Runtime) beginEnrollment(auth gatewaycore.AuthContext, list List) bool {
	authors := append([]string{}, list.Users...)
	seen := map[string]bool{}
	for _, author := range authors {
		seen[author] = true
	}
	for _, uri := range list.Publications {
		if did, ok := PublicationIdentity(uri); ok && !seen[did] {
			authors = append(authors, did)
			seen[did] = true
		}
	}
	if len(authors) == 0 {
		return true
	}
	key := Fingerprint(auth.DID, list, "initial-enrollment")
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.enrolled[key].After(r.Now()) {
		return true
	}
	if !r.enrollment[key] && !r.closed {
		r.enrollment[key] = true
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			select {
			case r.enrollmentLimiter <- struct{}{}:
			case <-r.ctx.Done():
				return
			}
			defer func() { <-r.enrollmentLimiter }()
			ctx, cancel := context.WithTimeout(r.ctx, time.Minute)
			defer cancel()
			var e error
			if r.Publication == nil || r.Publication.Enroller == nil {
				e = errors.New("enrollment unavailable")
			} else {
				for start := 0; start < len(authors); start += 20 {
					_, e = r.Publication.Enroller.Enroll(ctx, auth, authors[start:min(start+20, len(authors))], nil, true)
					if e != nil {
						break
					}
				}
			}
			r.mu.Lock()
			defer r.mu.Unlock()
			if e == nil && ctx.Err() == nil {
				r.enrolled[key] = r.Now().Add(5 * time.Minute)
			}
			delete(r.enrollment, key)
		}()
	}
	return false
}
