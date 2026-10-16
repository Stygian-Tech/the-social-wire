package publicationcore

import (
	"context"
	"encoding/json"
)

// A partial sidebar or a cold process must not require remote discovery when
// the viewer's canonical publication scopes have already been persisted.
func (s *Service) unreadScopeRows(ctx context.Context, viewer string, ids []string) ([]SidebarRow, error) {
	canonical := make([]string, 0, len(ids))
	for _, id := range ids {
		canonical = append(canonical, NormalizeATRepoParam(id))
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT publication_id,author_did,publication_at_uri,publication_scope_at_uris::text,publication_site_urls::text FROM appview_publication_scopes WHERE viewer_did=$1 AND publication_id=ANY($2::text[])`, viewer, canonical)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []SidebarRow{}
	for rows.Next() {
		var row SidebarRow
		var uris, sites string
		if err := rows.Scan(&row.PublicationID, &row.AuthorDID, &row.AppViewScope.PublicationATURI, &uris, &sites); err != nil {
			return nil, err
		}
		row.AppViewScope.AuthorDID = row.AuthorDID
		if err := json.Unmarshal([]byte(uris), &row.AppViewScope.PublicationScopeATURIs); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(sites), &row.AppViewScope.PublicationSiteURLs); err != nil {
			return nil, err
		}
		result = append(result, row)
	}
	return result, rows.Err()
}
