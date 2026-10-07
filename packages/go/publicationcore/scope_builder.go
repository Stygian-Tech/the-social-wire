package publicationcore

import (
	"context"
	"encoding/base64"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"sort"
	"strings"
)

func BuildScope(ctx context.Context, repo Repository, id, author string) AppViewScope {
	id = NormalizeATRepoParam(id)
	result := AppViewScope{AuthorDID: author, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{}}
	if strings.HasPrefix(id, "rss:") {
		result.AuthorDID = thinappviewcore.RSSAuthorDID
		if raw, e := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(id, "rss:")); e == nil {
			if feed := thinappviewcore.NormalizeFeedURL(string(raw)); feed != nil {
				result.PublicationSiteURLs = []string{*feed}
			}
		}
		return result
	}
	if strings.HasPrefix(id, "did:") {
		result.AuthorDID = id
		return result
	}
	did, col, key, ok := parseURI(id)
	if !ok {
		return result
	}
	result.AuthorDID = did
	result.PublicationATURI = &id
	uris := map[string]bool{}
	sites := map[string]bool{}
	merge := func(uri string, value map[string]any) {
		for _, key := range thinappviewcore.PublicationEquivalenceKeys(uri) {
			uris[key] = true
		}
		for _, key := range []string{"url", "siteUrl", "site", "homepage"} {
			if normalized := thinappviewcore.NormalizePublicationSiteURL(text(value, key)); normalized != "" {
				sites[normalized] = true
			}
		}
	}
	merge(id, nil)
	if record, e := repo.GetRecord(ctx, did, col, key, ""); e == nil && record != nil {
		value := recordValue(*record)
		merge(id, value)
		if site := thinappviewcore.NormalizePublicationSiteURL(text(value, "site")); site != "" {
			for _, collection := range []string{"site.standard.publication", "com.standard.publication", "app.offprint.publication"} {
				page, e := repo.ListRecords(ctx, did, collection, "", 50, true)
				if e != nil {
					continue
				}
				for _, sibling := range page.Records {
					v := recordValue(sibling)
					if other := thinappviewcore.NormalizePublicationSiteURL(text(v, "site")); other != "" && other == site {
						merge(sibling.URI, v)
					}
				}
			}
		}
	}
	for uri := range uris {
		result.PublicationScopeATURIs = append(result.PublicationScopeATURIs, uri)
	}
	for site := range sites {
		result.PublicationSiteURLs = append(result.PublicationSiteURLs, site)
	}
	sort.Strings(result.PublicationScopeATURIs)
	sort.Strings(result.PublicationSiteURLs)
	return result
}
