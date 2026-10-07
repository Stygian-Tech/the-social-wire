package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

// UnreadCountsByPublicationIDs resolves viewer-specific rows without a live
// discovery pass when either process memory or a durable sidebar can answer.
func (s *Service) UnreadCountsByPublicationIDs(ctx context.Context, auth gatewaycore.AuthContext, ids []string) (CounterSnapshot, error) {
	rowsByID := map[string]SidebarRow{}
	for _, id := range ids {
		if rows := s.SidebarRows(auth.DID, []string{id}); len(rows) > 0 {
			rowsByID[id] = rows[0]
		}
	}
	missing := func() []string {
		out := []string{}
		for _, id := range ids {
			if _, ok := rowsByID[id]; !ok {
				out = append(out, id)
			}
		}
		return out
	}
	merge := func(sidebar Sidebar) {
		if sidebar.ViewerDID != auth.DID {
			return
		}
		for _, id := range missing() {
			for _, row := range sidebar.AllPublicationRows {
				if IDsMatch(row.PublicationID, id) {
					rowsByID[id] = row
					break
				}
			}
		}
	}
	if len(missing()) > 0 && s.Cache != nil {
		if cached, err := s.Cache.Lookup(ctx, auth.DID, s.Now(), true); err == nil && cached != nil {
			merge(cached.Snapshot.Sidebar())
		}
	}
	if len(missing()) > 0 {
		sidebar, err := s.Sidebar(ctx, auth, "full")
		if err != nil {
			return CounterSnapshot{}, err
		}
		merge(sidebar)
	}
	rows := []SidebarRow{}
	for _, id := range ids {
		if row, ok := rowsByID[id]; ok {
			rows = append(rows, row)
		}
	}
	snapshot, err := s.CachedCounters(ctx, auth.DID, rows)
	if err != nil {
		if ctx.Err() != nil {
			return CounterSnapshot{}, ctx.Err()
		}
		snapshot = CounterSnapshot{Counts: map[string]int{}, Generation: counterGeneration(s.Now()), Accuracy: "estimated", CountedAt: s.Now(), Dirty: true, MissingPublicationIDs: rowIDs(rows)}
		for _, row := range rows {
			snapshot.Counts[row.PublicationID] = 0
		}
	}
	if snapshot.Dirty || len(snapshot.MissingPublicationIDs) > 0 {
		s.launch("unread-refresh:"+auth.DID, func(work context.Context) { _, _ = s.RefreshCounters(work, auth.DID, rows) })
	}
	if s.Cache != nil && len(snapshot.Counts) > 0 {
		_ = s.Cache.storeUnread(ctx, auth.DID, snapshot.Counts, s.Now())
	}
	return snapshot, nil
}
