package publicationcore

import (
	"context"
	"sort"
	"sync"
)

func uniqueRows(rows []DiscoveredRow) []DiscoveredRow {
	byID := map[string]DiscoveredRow{}
	for _, row := range rows {
		byID[row.PublicationID] = row
	}
	out := []DiscoveredRow{}
	for _, row := range byID {
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PublicationID < out[j].PublicationID })
	return out
}
func (s *Service) BuildSidebar(ctx context.Context, discovery DiscoveryContext, phase string) (Sidebar, error) {
	priority := uniqueRows(append(append(append([]DiscoveredRow{}, discovery.MyPublications...), discovery.Unfoldered...), discovery.Following...))
	folderRows := []DiscoveredRow{}
	for _, folder := range discovery.Folders {
		for _, row := range discovery.Subscribed {
			pref := text(discovery.PrefsByPublicationID[row.PublicationID].Value, "folderId")
			if pref == folder.URI || pref == folder.RKey {
				folderRows = append(folderRows, row)
			}
		}
	}
	build := discovery.UniqueRows
	if phase == "priority" {
		build = priority
	} else if phase == "folderPublications" {
		build = uniqueRows(folderRows)
	}
	built := map[string]SidebarRow{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 25)
	for _, row := range build {
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			wg.Wait()
			return Sidebar{}, ctx.Err()
		}
		wg.Add(1)
		go func(row DiscoveredRow) {
			defer wg.Done()
			defer func() { <-slots }()
			scope := s.Scope(ctx, row.PublicationID, row.AuthorDID)
			r := SidebarRow{PublicationID: row.PublicationID, SubscriptionPublicationID: row.SubscriptionPublicationID, AuthorDID: row.AuthorDID, AuthorHandle: row.AuthorHandle, Title: row.Title, IconURL: row.IconURL, AvatarURL: row.AvatarURL, DiscoveredAt: row.DiscoveredAt, AppViewScope: scope}
			mu.Lock()
			built[row.PublicationID] = r
			mu.Unlock()
		}(row)
	}
	wg.Wait()
	if e := ctx.Err(); e != nil {
		return Sidebar{}, e
	}
	s.mu.Lock()
	if s.rows[discovery.ViewerDID] == nil {
		s.rows[discovery.ViewerDID] = map[string]SidebarRow{}
	}
	for id, row := range built {
		for _, key := range LookupKeys(id) {
			s.rows[discovery.ViewerDID][key] = row
		}
	}
	cache := map[string]SidebarRow{}
	for key, row := range s.rows[discovery.ViewerDID] {
		cache[key] = row
	}
	s.mu.Unlock()
	convert := func(rows []DiscoveredRow) []SidebarRow {
		out := []SidebarRow{}
		for _, row := range rows {
			if r, ok := cache[row.PublicationID]; ok {
				out = append(out, r)
			}
		}
		return out
	}
	result := Sidebar{ViewerDID: discovery.ViewerDID, Folders: discovery.Folders, PublicationPrefs: discovery.Prefs, FolderSections: []FolderSection{}, AllPublicationRows: convert(discovery.UniqueRows), MyPublications: convert(discovery.MyPublications), SubscribedUnfoldered: convert(discovery.Unfoldered), FollowingTabPublications: convert(discovery.Following), EnrollAuthorDIDs: discovery.EnrollAuthorDIDs, RefreshedAt: s.Now()}
	for _, folder := range discovery.Folders {
		section := FolderSection{FolderURI: folder.URI, FolderRKey: folder.RKey, Name: text(folder.Value, "name"), Publications: []SidebarRow{}}
		if section.Name == "" {
			section.Name = folder.RKey
		}
		if phase != "priority" {
			for _, row := range discovery.Subscribed {
				pref := text(discovery.PrefsByPublicationID[row.PublicationID].Value, "folderId")
				if pref == folder.URI || pref == folder.RKey {
					section.Publications = append(section.Publications, convert([]DiscoveredRow{row})...)
				}
			}
		}
		result.FolderSections = append(result.FolderSections, section)
	}
	if phase == "priority" {
		result.AllPublicationRows = convert(priority)
	} else if phase == "folderPublications" {
		result.Folders = []FolderRecord{}
		result.PublicationPrefs = []PreferenceRecord{}
		result.MyPublications = []SidebarRow{}
		result.SubscribedUnfoldered = []SidebarRow{}
		result.FollowingTabPublications = []SidebarRow{}
		result.EnrollAuthorDIDs = []string{}
		result.AllPublicationRows = []SidebarRow{}
		for _, section := range result.FolderSections {
			result.AllPublicationRows = append(result.AllPublicationRows, section.Publications...)
		}
	}
	// Source returns sidebar even when durable scope persistence is unavailable; read paths
	// still enforce their own database readiness and never substitute client scopes.
	_ = (ProjectionStore{DB: s.DB}).Persist(ctx, result, phase == "full")
	return result, nil
}
