package publicationcore

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

// RefreshEnrollmentCounters makes explicit enrollment success include a fresh
// count for the requested sources, including rows built on another replica.
func (s *Service) RefreshEnrollmentCounters(ctx context.Context, viewer string, authors, feeds []string) error {
	rows, err := s.enrollmentCounterRows(ctx, viewer, authors, feeds)
	if err != nil || len(rows) == 0 {
		return err
	}
	// Wait for an older recount rather than using RefreshCounters' stale fallback
	// or racing its cache write. Keep the explicit request bounded under contention.
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if s.Cache != nil {
		for {
			lease, leaseErr := s.Cache.Projection.AcquireRefreshLease(ctx, "unread", viewer, 10*time.Second)
			if leaseErr != nil {
				return leaseErr
			}
			if lease != nil {
				defer s.renew(ctx, lease)()
				break
			}
			if err := waitContext(ctx, 100*time.Millisecond); err != nil {
				return err
			}
		}
	}
	snapshot, err := s.Counters(ctx, viewer, rows, true)
	if err != nil {
		return err
	}
	if s.Cache != nil {
		return s.Cache.storeUnread(ctx, viewer, snapshot.Counts, snapshot.CountedAt)
	}
	return nil
}

func (s *Service) enrollmentCounterRows(ctx context.Context, viewer string, authors, feeds []string) ([]SidebarRow, error) {
	wantedAuthors, wantedFeeds := map[string]bool{}, map[string]bool{}
	for _, author := range authors {
		if author = strings.TrimSpace(author); author != "" && author != thinappviewcore.RSSAuthorDID {
			wantedAuthors[author] = true
		}
	}
	for _, raw := range feeds {
		if feed := thinappviewcore.NormalizeFeedURL(raw); feed != nil {
			wantedFeeds[*feed] = true
		}
	}
	selected := map[string]SidebarRow{}
	add := func(row SidebarRow) {
		if row.PublicationID == "" {
			return
		}
		author := row.AppViewScope.AuthorDID
		if author == thinappviewcore.RSSAuthorDID {
			for _, raw := range row.AppViewScope.PublicationSiteURLs {
				if feed := thinappviewcore.NormalizeFeedURL(raw); feed != nil && wantedFeeds[*feed] {
					selected[row.PublicationID] = row
					return
				}
			}
		} else if wantedAuthors[author] {
			selected[row.PublicationID] = row
		}
	}
	if len(wantedAuthors)+len(wantedFeeds) == 0 {
		return nil, ctx.Err()
	}
	// ProjectionStore.Persist keeps normalized scope keys. Query only this viewer's
	// requested sources; no sidebar discovery or follow graph traversal is needed.
	if s.DB != nil {
		authorIDs, feedURLs := []string{}, []string{}
		for author := range wantedAuthors {
			authorIDs = append(authorIDs, author)
		}
		for feed := range wantedFeeds {
			feedURLs = append(feedURLs, feed)
		}
		rows, err := s.DB.QueryContext(ctx, `SELECT publication_id,author_did,publication_at_uri,publication_scope_at_uris::text,publication_site_urls::text FROM appview_publication_scopes WHERE viewer_did=$1 AND ((author_did<>$3 AND author_did=ANY($2::text[])) OR (author_did=$3 AND scope_keys ?| $4::text[]))`, viewer, authorIDs, thinappviewcore.RSSAuthorDID, feedURLs)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var row SidebarRow
			var uris, sites string
			if err = rows.Scan(&row.PublicationID, &row.AppViewScope.AuthorDID, &row.AppViewScope.PublicationATURI, &uris, &sites); err != nil {
				return nil, err
			}
			if err = json.Unmarshal([]byte(uris), &row.AppViewScope.PublicationScopeATURIs); err != nil {
				return nil, err
			}
			if err = json.Unmarshal([]byte(sites), &row.AppViewScope.PublicationSiteURLs); err != nil {
				return nil, err
			}
			row.AuthorDID = row.AppViewScope.AuthorDID
			add(row)
		}
		if err = rows.Err(); err != nil {
			return nil, err
		}
	}
	s.mu.Lock()
	for _, row := range s.rows[viewer] {
		add(row)
	}
	s.mu.Unlock()
	result := make([]SidebarRow, 0, len(selected))
	for _, row := range selected {
		result = append(result, row)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].PublicationID < result[j].PublicationID })
	return result, ctx.Err()
}
