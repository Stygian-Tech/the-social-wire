package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

var publicationCollections = []string{"site.standard.publication", "com.standard.publication", "app.offprint.publication"}
var contentCollections = []string{"site.standard.document", "com.standard.document", "site.standard.entry", "com.standard.entry"}

func discoverAuthor(ctx context.Context, repo Repository, did, handle, displayName string, at time.Time) []DiscoveredRow {
	pds, _ := repo.ResolvePDS(ctx, did)
	for _, collection := range publicationCollections {
		page, e := repo.ListRecords(ctx, did, collection, "", 50, true)
		if e != nil || len(page.Records) == 0 {
			continue
		}
		rows := []DiscoveredRow{}
		for _, r := range page.Records {
			value := recordValue(r)
			title := text(value, "title")
			if title == "" {
				title = text(value, "name")
			}
			if title == "" {
				title = displayName
			}
			if title == "" {
				title = handle
			}
			uri := r.URI
			h := handle
			rows = append(rows, DiscoveredRow{PublicationID: uri, SubscriptionPublicationID: &uri, AuthorDID: did, AuthorHandle: &h, Title: title, IconURL: thinappviewcore.PublicationIconURL(value, did, pds), DiscoveredAt: at})
		}
		return rows
	}
	for _, collection := range contentCollections {
		page, e := repo.ListRecords(ctx, did, collection, "", 1, true)
		if e == nil && len(page.Records) > 0 {
			title := displayName
			if title == "" {
				title = handle
			}
			h := handle
			return []DiscoveredRow{{PublicationID: did, AuthorDID: did, AuthorHandle: &h, Title: title, DiscoveredAt: at}}
		}
	}
	return []DiscoveredRow{}
}
func rowFromURI(ctx context.Context, repo Repository, raw string, at time.Time) *DiscoveredRow {
	normal := NormalizeATRepoParam(raw)
	did, collection, key, ok := parseURI(normal)
	if !ok || (collection != "site.standard.publication" && collection != "com.standard.publication") {
		return nil
	}
	record, e := repo.GetRecord(ctx, did, collection, key, "")
	if e != nil || record == nil {
		return nil
	}
	value := recordValue(*record)
	title := text(value, "title")
	if title == "" {
		title = text(value, "name")
	}
	if title == "" {
		title = key
	}
	pds, _ := repo.ResolvePDS(ctx, did)
	return &DiscoveredRow{PublicationID: normal, SubscriptionPublicationID: &normal, AuthorDID: did, AuthorHandle: &did, Title: title, IconURL: thinappviewcore.PublicationIconURL(value, did, pds), DiscoveredAt: at}
}
func FollowDiscovery(ctx context.Context, repo Repository, client *http.Client, viewer string, at time.Time) []DiscoveredRow {
	subjects := map[string]bool{viewer: true}
	cursor := ""
	seen := map[string]bool{}
	for len(subjects) < 500 {
		page, e := repo.ListRecords(ctx, viewer, "app.bsky.graph.follow", cursor, 100, false)
		if e != nil {
			break
		}
		for _, record := range page.Records {
			if subject := text(recordValue(record), "subject"); subject != "" {
				subjects[subject] = true
			}
			if len(subjects) >= 500 {
				break
			}
		}
		if page.Cursor == "" || seen[page.Cursor] {
			break
		}
		seen[page.Cursor] = true
		cursor = page.Cursor
	}
	if len(subjects) < 500 && client != nil {
		cursor = ""
		seen = map[string]bool{}
		for len(subjects) < 500 {
			q := url.Values{"actor": {viewer}, "limit": {"100"}}
			if cursor != "" {
				q.Set("cursor", cursor)
			}
			var page struct {
				Follows []struct{ DID string }
				Cursor  string
			}
			if publicJSON(ctx, client, queryURL("https://public.api.bsky.app", "/xrpc/app.bsky.graph.getFollows", q), 256<<10, &page) != nil {
				break
			}
			for _, follow := range page.Follows {
				if follow.DID != "" {
					subjects[follow.DID] = true
				}
				if len(subjects) >= 500 {
					break
				}
			}
			if page.Cursor == "" || seen[page.Cursor] {
				break
			}
			seen[page.Cursor] = true
			cursor = page.Cursor
		}
	}
	rows := discoverAuthor(ctx, repo, viewer, "You", "My Publications", at)
	others := []string{}
	for did := range subjects {
		if did != viewer {
			others = append(others, did)
		}
	}
	sort.Strings(others)
	jobs := make(chan string)
	result := make(chan []DiscoveredRow)
	var workers sync.WaitGroup
	for i := 0; i < min(25, len(others)); i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for did := range jobs {
				found := discoverAuthor(ctx, repo, did, did, "", at)
				select {
				case result <- found:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	go func() {
		defer close(jobs)
		for _, did := range others {
			select {
			case jobs <- did:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { workers.Wait(); close(result) }()
	for found := range result {
		rows = append(rows, found...)
	}
	byID := map[string]DiscoveredRow{}
	for _, row := range rows {
		byID[row.PublicationID] = row
	}
	rows = []DiscoveredRow{}
	for _, row := range byID {
		rows = append(rows, row)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := strings.ToLower(rows[i].Title), strings.ToLower(rows[j].Title)
		if a == b {
			return rows[i].PublicationID < rows[j].PublicationID
		}
		return a < b
	})
	return rows
}
