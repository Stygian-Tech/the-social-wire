package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"strings"
	"time"
)

type Emit func(map[string]any) error

func event(kind string, payload any) map[string]any {
	return map[string]any{"kind": kind, kind: payload}
}
func sparse(counts map[string]int) map[string]int {
	out := map[string]int{}
	for id, n := range counts {
		if n > 0 {
			out[id] = n
		}
	}
	return out
}
func rowIDs(rows []SidebarRow) []string {
	out := []string{}
	for _, row := range rows {
		out = append(out, row.PublicationID)
	}
	return out
}
func uniqueSidebarRows(rows []SidebarRow) []SidebarRow {
	out := []SidebarRow{}
	seen := map[string]bool{}
	for _, row := range rows {
		if !seen[row.PublicationID] {
			seen[row.PublicationID] = true
			out = append(out, row)
		}
	}
	return out
}
func (s *Service) emitCounts(ctx context.Context, viewer string, rows []SidebarRow, emit Emit) (map[string]int, error) {
	snapshot, e := s.CachedCounters(ctx, viewer, rows)
	if e != nil {
		return nil, e
	}
	return s.emitCounterSnapshot(viewer, rows, snapshot, emit)
}
func (s *Service) emitCounterSnapshot(viewer string, rows []SidebarRow, snapshot CounterSnapshot, emit Emit) (map[string]int, error) {
	var e error
	if e = emit(event("unreadCounts", map[string]any{"counts": sparse(snapshot.Counts), "replacePublicationIds": rowIDs(rows), "generation": snapshot.Generation, "accuracy": snapshot.Accuracy, "countedAt": snapshot.CountedAt.UTC().Format(time.RFC3339)})); e != nil {
		return nil, e
	}
	if snapshot.Dirty || len(snapshot.MissingPublicationIDs) > 0 {
		s.launch("counts:"+viewer+":"+strings.Join(rowIDs(rows), "|"), func(work context.Context) { _, _ = s.RefreshCounters(work, viewer, rows) })
	}
	return snapshot.Counts, nil
}
func (s *Service) emitFolders(payload FolderPayload, at time.Time, emit Emit) error {
	for _, folder := range payload.FolderSections {
		if e := emit(event("sidebarSection", map[string]any{"sectionKey": "folder:" + folder.FolderRKey, "folderRkey": folder.FolderRKey, "folderUri": folder.FolderURI, "publications": folder.Publications, "sectionGeneration": counterGeneration(at), "refreshedAt": at.UTC().Format(time.RFC3339)})); e != nil {
			return e
		}
	}
	return emit(event("sidebarFolders", payload))
}
func (s *Service) emitSelected(ctx context.Context, auth gatewaycore.AuthContext, sidebar Sidebar, counts map[string]int, emit Emit) (FirstPage, error) {
	for _, row := range append(append(append([]SidebarRow{}, sidebar.MyPublications...), sidebar.SubscribedUnfoldered...), sidebar.FollowingTabPublications...) {
		if counts[row.PublicationID] <= 0 {
			continue
		}
		if e := emit(event("selectedPublication", map[string]any{"publicationId": row.PublicationID})); e != nil {
			return FirstPage{}, e
		}
		page, e := s.SelectedPage(ctx, auth, row)
		if e != nil {
			return FirstPage{}, e
		}
		entries := []map[string]any{}
		for _, entry := range page.Page.Entries {
			v := map[string]any{"entryId": entry.EntryID, "title": entry.Title, "publishedAt": entry.PublishedAt.UTC().Format(time.RFC3339)}
			if entry.Summary != nil {
				v["summary"] = *entry.Summary
			}
			if entry.ThumbnailURL != nil {
				v["thumbnailUrl"] = *entry.ThumbnailURL
			}
			if entry.ThumbnailFallbackURL != nil {
				v["thumbnailFallbackUrl"] = *entry.ThumbnailFallbackURL
			}
			if entry.OriginalURL != nil {
				v["originalUrl"] = *entry.OriginalURL
			}
			entries = append(entries, v)
		}
		payload := map[string]any{"publicationId": row.PublicationID, "entries": entries, "source": page.Source}
		if page.Page.Cursor != nil {
			payload["cursor"] = *page.Page.Cursor
		}
		if page.CachedAt != nil {
			payload["cachedAt"] = page.CachedAt.UTC().Format(time.RFC3339)
		}
		if page.ExpiresAt != nil {
			payload["expiresAt"] = page.ExpiresAt.UTC().Format(time.RFC3339)
		}
		return page, emit(event("entriesPage", payload))
	}
	return FirstPage{Source: "live_projection"}, nil
}
func (s *Service) SelectedPage(ctx context.Context, auth gatewaycore.AuthContext, row SidebarRow) (FirstPage, error) {
	done := make(chan struct{})
	if s.Enroller != nil {
		started := s.launch("selected:"+auth.DID+":"+row.PublicationID, func(work context.Context) {
			defer close(done)
			if row.AppViewScope.AuthorDID == thinappviewcore.RSSAuthorDID {
				_, _ = s.Enroller.IngestSubscriptions(work, auth, row.AppViewScope.PublicationSiteURLs)
			} else {
				_, _ = s.Enroller.Enroll(work, auth, []string{row.AppViewScope.AuthorDID}, nil, true)
			}
			_, _ = s.LivePage(work, auth, row, 50)
		})
		if !started {
			done = nil
		}
	}
	if done != nil {
		select {
		case <-done:
			if page, e := s.LivePage(ctx, auth, row, 50); e != nil {
				return FirstPage{}, e
			} else if page != nil {
				return *page, nil
			}
		default:
		}
	}
	if s.Cache != nil {
		if page, e := s.Cache.CachedPage(ctx, auth.DID, row.PublicationID, 50, s.Now()); e != nil {
			return FirstPage{}, e
		} else if page != nil {
			if page.Stale {
				s.launch("page:"+auth.DID+":"+row.PublicationID, func(work context.Context) { _, _ = s.LivePage(work, auth, row, 50) })
			}
			return *page, nil
		}
	}
	return FirstPage{Page: appviewcore.EntryPage{Entries: []appviewcore.Entry{}}, Source: "unavailable"}, nil
}
func (s *Service) warm(auth gatewaycore.AuthContext, priority Sidebar) {
	if s.Enroller == nil {
		return
	}
	s.launch("warm:"+auth.DID, func(ctx context.Context) {
		authors := []string{}
		seen := map[string]bool{}
		for _, row := range append(append(append([]SidebarRow{}, priority.MyPublications...), priority.SubscribedUnfoldered...), priority.FollowingTabPublications...) {
			did := row.AppViewScope.AuthorDID
			if did != thinappviewcore.RSSAuthorDID && !seen[did] {
				authors = append(authors, did)
				seen[did] = true
			}
		}
		_, _ = s.Enroller.Enroll(ctx, auth, authors, nil, true)
		_, _ = s.Enroller.IngestSubscriptions(ctx, auth, nil)
		remaining := []string{}
		for _, did := range priority.EnrollAuthorDIDs {
			if !seen[did] {
				remaining = append(remaining, did)
			}
		}
		_, _ = s.Enroller.Enroll(ctx, auth, remaining, nil, false)
	})
}
func (s *Service) Bootstrap(ctx context.Context, auth gatewaycore.AuthContext, includeLists bool, emit Emit) error {
	at := s.Now()
	run := func() error {
		if s.Cache != nil {
			if cached, e := s.Cache.Lookup(ctx, auth.DID, at, false); e != nil {
				return e
			} else if cached != nil {
				if e = s.emitCached(ctx, auth, *cached, includeLists, emit); e != nil {
					return e
				}
				s.warm(auth, cached.Snapshot.Priority)
				if cached.Stale {
					s.launch("sidebar:"+auth.DID, func(work context.Context) { s.rebuild(work, auth) })
				}
				return nil
			}
		}
		var lease *thinappviewcore.RefreshLease
		if s.Cache != nil {
			var e error
			lease, e = s.Cache.Projection.AcquireRefreshLease(ctx, "sidebar", auth.DID, 30*time.Second)
			if e != nil {
				return e
			}
			if lease == nil {
				if e = waitContext(ctx, 250*time.Millisecond); e != nil {
					return e
				}
				if cached, e := s.Cache.Lookup(ctx, auth.DID, s.Now(), false); e != nil {
					return e
				} else if cached != nil {
					return s.emitCached(ctx, auth, *cached, includeLists, emit)
				}
			}
		}
		stop := s.renew(ctx, lease)
		defer stop()
		priority, discovery, e := s.Priority(ctx, auth, false)
		if e != nil {
			return e
		}
		if e = emit(event("sidebarPriority", priority)); e != nil {
			return e
		}
		rows := uniqueSidebarRows(append(append(append(append([]SidebarRow{}, priority.AllPublicationRows...), priority.MyPublications...), priority.SubscribedUnfoldered...), priority.FollowingTabPublications...))

		type chunk struct {
			sidebar  *Sidebar
			counters *CounterSnapshot
			err      error
		}
		chunks := make(chan chunk, 2)
		work, cancel := context.WithCancel(ctx)
		defer cancel()
		go func() {
			sidebar, e := s.BuildSidebar(work, discovery, "folderPublications")
			chunks <- chunk{sidebar: &sidebar, err: e}
		}()
		go func() {
			snapshot, e := s.CachedCounters(work, auth.DID, rows)
			chunks <- chunk{counters: &snapshot, err: e}
		}()
		var payload FolderPayload
		selection := FirstPage{Source: "live_projection"}
		var phaseError error
		for i := 0; i < 2; i++ {
			result := <-chunks
			if phaseError != nil {
				continue
			}
			if result.err != nil {
				phaseError = result.err
				cancel()
				continue
			}
			if result.sidebar != nil {
				payload = FolderPayload{result.sidebar.FolderSections, result.sidebar.AllPublicationRows}
				phaseError = s.emitFolders(payload, at, emit)
			} else {
				counts, err := s.emitCounterSnapshot(auth.DID, rows, *result.counters, emit)
				phaseError = err
				if phaseError == nil {
					selection, phaseError = s.emitSelected(ctx, auth, priority, counts, emit)
				}
			}
			if phaseError != nil {
				cancel()
			}
		}
		if phaseError != nil {
			return phaseError
		}
		known := map[string]bool{}
		for _, row := range rows {
			known[row.PublicationID] = true
		}
		extra := []SidebarRow{}
		for _, row := range payload.AllPublicationRows {
			if !known[row.PublicationID] {
				extra = append(extra, row)
			}
		}
		if len(extra) > 0 {
			if _, e = s.emitCounts(ctx, auth.DID, extra, emit); e != nil {
				return e
			}
		}
		if includeLists {
			if e = s.emitLists(ctx, auth, emit); e != nil {
				return e
			}
		}
		completedAt := at
		if selection.Source == "projection_cache" && selection.CachedAt != nil {
			completedAt = *selection.CachedAt
		}
		if e = emit(event("done", map[string]any{"refreshedAt": completedAt.UTC().Format(time.RFC3339), "source": selection.Source})); e != nil {
			return e
		}
		if s.Cache != nil {
			_ = s.Cache.Store(ctx, auth.DID, BootstrapSnapshot{1, priority, &payload}, s.Now())
		}
		s.warm(auth, priority)
		return nil
	}
	if e := run(); e != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if write := emit(event("error", map[string]any{"message": "Bootstrap projection unavailable."})); write != nil {
			return write
		}
		return emit(event("done", map[string]any{"refreshedAt": at.UTC().Format(time.RFC3339), "source": "unavailable"}))
	}
	return nil
}
func (s *Service) emitCached(ctx context.Context, auth gatewaycore.AuthContext, cached CachedSnapshot, includeLists bool, emit Emit) error {
	snapshot := cached.Snapshot
	if e := emit(event("sidebarPriority", snapshot.Priority)); e != nil {
		return e
	}
	if snapshot.FolderPayload != nil {
		if e := s.emitFolders(*snapshot.FolderPayload, cached.CachedAt, emit); e != nil {
			return e
		}
	}
	rows := uniqueSidebarRows(allSidebarRows(snapshot.Sidebar()))
	counts, e := s.emitCounts(ctx, auth.DID, rows, emit)
	if e != nil {
		return e
	}
	if _, e = s.emitSelected(ctx, auth, snapshot.Priority, counts, emit); e != nil {
		return e
	}
	if includeLists {
		if e = s.emitLists(ctx, auth, emit); e != nil {
			return e
		}
	}
	return emit(event("done", map[string]any{"refreshedAt": cached.CachedAt.UTC().Format(time.RFC3339), "source": "projection_cache"}))
}
func (s *Service) emitLists(ctx context.Context, auth gatewaycore.AuthContext, emit Emit) error {
	if s.Lists == nil {
		return nil
	}
	value, e := s.Lists(ctx, auth)
	if e != nil {
		return emit(event("warning", map[string]any{"message": "Lists could not be refreshed. Other feeds remain available."}))
	}
	return emit(map[string]any{"kind": "lists", "lists": value})
}
func (s *Service) rebuild(ctx context.Context, auth gatewaycore.AuthContext) {
	var lease *thinappviewcore.RefreshLease
	if s.Cache != nil {
		lease, _ = s.Cache.Projection.AcquireRefreshLease(ctx, "sidebar", auth.DID, 30*time.Second)
		if lease == nil {
			return
		}
	}
	stop := s.renew(ctx, lease)
	defer stop()
	discovery, e := s.Discover(ctx, auth.DID, true)
	if e != nil {
		return
	}
	if _, e = s.BuildSidebar(ctx, discovery, "full"); e != nil {
		return
	}
	priority, e := s.BuildSidebar(ctx, discovery, "priority")
	if e != nil {
		return
	}
	folders, e := s.BuildSidebar(ctx, discovery, "folderPublications")
	if e != nil {
		return
	}
	if s.Cache != nil {
		payload := FolderPayload{folders.FolderSections, folders.AllPublicationRows}
		_ = s.Cache.Store(ctx, auth.DID, BootstrapSnapshot{1, priority, &payload}, s.Now())
	}
}
func (s *Service) renew(ctx context.Context, lease *thinappviewcore.RefreshLease) func() {
	if lease == nil || s.Cache == nil {
		return func() {}
	}
	work, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(lease.TTL / 3)
		defer ticker.Stop()
		for {
			select {
			case <-work.Done():
				return
			case <-ticker.C:
				ok, e := s.Cache.Projection.RenewRefreshLease(work, *lease)
				if e != nil || !ok {
					return
				}
			}
		}
	}()
	return func() {
		cancel()
		<-done
		release, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		_ = s.Cache.Projection.ReleaseRefreshLease(release, *lease)
	}
}
