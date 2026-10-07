package publicationcore

import "context"

// RebuildFeedProjectionFromCachedSidebar repairs derived membership without a
// public-repository discovery fanout. Stale snapshots are useful during recovery.
func (s *Service) RebuildFeedProjectionFromCachedSidebar(ctx context.Context, viewer string) bool {
	if s.Cache == nil || s.DB == nil {
		return false
	}
	hit, err := s.Cache.Lookup(ctx, viewer, s.Now(), true)
	if err != nil || hit == nil {
		return false
	}
	sidebar := hit.Snapshot.Sidebar()
	if sidebar.ViewerDID != viewer {
		return false
	}
	return (ProjectionStore{DB: s.DB}).Persist(ctx, sidebar, true) == nil
}
