package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

func Discover(ctx context.Context, repo Repository, client *http.Client, viewer string, includeFollows bool, priorFollowing []DiscoveredRow, at time.Time) (DiscoveryContext, error) {
	result := DiscoveryContext{ViewerDID: viewer, Folders: []FolderRecord{}, Prefs: []PreferenceRecord{}, Following: []DiscoveredRow{}, PrefsByPublicationID: map[string]PreferenceRecord{}}
	collections := []string{"app.thesocialwire.folder", "app.thesocialwire.publicationPrefs", "site.standard.graph.subscription", "app.skyreader.feed.subscription"}
	records := make([][]gatewaycore.RepoRecord, 4)
	errs := make([]error, 4)
	var wg sync.WaitGroup
	for i, col := range collections {
		wg.Add(1)
		go func(i int, col string) {
			defer wg.Done()
			pages := 20
			if i == 0 {
				pages = 10
			}
			records[i], errs[i] = listAll(ctx, repo, viewer, col, pages)
		}(i, col)
	}
	discovered := []DiscoveredRow{}
	if includeFollows {
		wg.Add(1)
		go func() { defer wg.Done(); discovered = FollowDiscovery(ctx, repo, client, viewer, at) }()
	}
	wg.Wait()
	for _, e := range errs {
		if e != nil {
			return result, e
		}
	}
	for _, r := range records[0] {
		_, _, key, ok := parseURI(r.URI)
		if !ok {
			key = r.URI
		}
		result.Folders = append(result.Folders, FolderRecord{URI: r.URI, RKey: key, Value: recordValue(r)})
	}
	for _, r := range records[1] {
		v := recordValue(r)
		if id := text(v, "publicationId"); id != "" {
			result.Prefs = append(result.Prefs, PreferenceRecord{URI: r.URI, PublicationID: id, Value: v})
		}
	}
	rss := RSSRows(records[3], at)
	subscriptions := []string{}
	existing := map[string]bool{}
	for _, r := range append(append([]DiscoveredRow{}, discovered...), rss...) {
		for _, key := range MatchKeys(r) {
			existing[key] = true
		}
	}
	orphans := []DiscoveredRow{}
	seen := map[string]bool{}
	for _, r := range records[2] {
		id := text(recordValue(r), "publication")
		if id == "" {
			continue
		}
		subscriptions = append(subscriptions, id)
		present := false
		for _, key := range LookupKeys(id) {
			present = present || existing[key]
		}
		if !present && !seen[id] {
			seen[id] = true
			if row := rowFromURI(ctx, repo, id, at); row != nil {
				orphans = append(orphans, *row)
			}
		}
	}
	visible := FilterHidden(append(discovered, orphans...), result.Prefs)
	visibleRSS := FilterHidden(rss, result.Prefs)
	graph, following := Segment(visible, viewer, subscriptions)
	result.Subscribed = MergeSubscribed(graph, visibleRSS, FilterHidden(orphans, result.Prefs))
	result.PrefsByPublicationID = PreferencesByID(result.Prefs)
	for _, row := range result.Subscribed {
		if owns(row, viewer) {
			result.MyPublications = append(result.MyPublications, row)
		} else if folder := text(result.PrefsByPublicationID[row.PublicationID].Value, "folderId"); folder == "" {
			result.Unfoldered = append(result.Unfoldered, row)
		}
	}
	if includeFollows {
		for _, row := range following {
			if !owns(row, viewer) {
				result.Following = append(result.Following, row)
			}
		}
	} else {
		result.Following = priorFollowing
	}
	unique := map[string]DiscoveredRow{}
	authors := map[string]bool{}
	for _, row := range append(visible, visibleRSS...) {
		unique[row.PublicationID] = row
		if strings.HasPrefix(row.AuthorDID, "did:plc:") || strings.HasPrefix(row.AuthorDID, "did:web:") && row.AuthorDID != "did:web:skyreader.rss" {
			authors[row.AuthorDID] = true
		}
	}
	for _, row := range unique {
		result.UniqueRows = append(result.UniqueRows, row)
	}
	sort.Slice(result.UniqueRows, func(i, j int) bool { return result.UniqueRows[i].PublicationID < result.UniqueRows[j].PublicationID })
	for author := range authors {
		result.EnrollAuthorDIDs = append(result.EnrollAuthorDIDs, author)
	}
	sort.Strings(result.EnrollAuthorDIDs)
	return result, nil
}
