package appviewcore

import (
	"context"
	"time"
)

// ScopedUnreadCount is the compatibility author/scope query. Read marks and
// replicated watermarks remain specific to the authenticated viewer.
func (s ContentReader) ScopedUnreadCount(ctx context.Context, viewer string, scope PublicationScope, at time.Time) (int, error) {
	keys := PublicationSiteKeys(scope)
	if keys == nil {
		keys = []string{}
	}
	scoped := scope.PublicationATURI != nil || len(scope.PublicationScopeATURIs) > 0 || len(scope.PublicationSiteURLs) > 0
	var count int
	err := s.DB.QueryRowContext(ctx, `SELECT COUNT(*)::int FROM content_items ci LEFT JOIN read_marks rm ON rm.viewer_did=$1 AND rm.subject_uri=ci.uri LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$1 AND uo.subject_uri=ci.uri LEFT JOIN LATERAL appview_effective_entry_read_state($1,ci.uri,ci.author_did,ci.publication_site,ci.created_at,rm.subject_uri,uo.subject_uri) read_state ON TRUE WHERE ci.author_did=$2 AND ci.expires_at>$3 AND read_state.read_uri IS NULL AND ($4::boolean=FALSE OR ci.publication_site=ANY($5::text[]))`, viewer, scope.AuthorDID, at, scoped, keys).Scan(&count)
	return count, err
}
