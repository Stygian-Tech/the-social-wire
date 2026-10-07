package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func (s *Service) ResolveScopes(ctx context.Context, auth gatewaycore.AuthContext, selector appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error) {
	if e := selector.Validate(); e != nil {
		return nil, e
	}
	sidebar, e := s.Sidebar(ctx, auth, "full")
	if e != nil {
		return nil, e
	}
	rows := []SidebarRow{}
	switch selector.Kind {
	case "publication":
		for _, row := range allSidebarRows(sidebar) {
			if IDsMatch(row.PublicationID, *selector.PublicationID) {
				rows = append(rows, row)
			}
		}
	case "subscribed":
		rows = append(rows, sidebar.SubscribedUnfoldered...)
		for _, section := range sidebar.FolderSections {
			rows = append(rows, section.Publications...)
		}
	case "following":
		rows = sidebar.FollowingTabPublications
	case "folder":
		for _, section := range sidebar.FolderSections {
			if section.FolderRKey == *selector.FolderRKey || section.FolderURI == *selector.FolderRKey {
				rows = append(rows, section.Publications...)
			}
		}
	}
	out := []appviewcore.PublicationScope{}
	seen := map[string]bool{}
	for _, row := range rows {
		if !seen[row.PublicationID] {
			seen[row.PublicationID] = true
			out = append(out, row.AppViewScope.ReadScope(row.PublicationID))
		}
	}
	return out, nil
}
