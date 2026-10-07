package listcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"sync"
	"time"
)

func ListScopes(list List) []appviewcore.PublicationScope {
	scopes := []appviewcore.PublicationScope{}
	authors := map[string]bool{}
	for _, did := range list.Users {
		authors[did] = true
		scopes = append(scopes, appviewcore.PublicationScope{PublicationID: did, AuthorDID: did, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{}})
	}
	for _, uri := range list.Publications {
		did, ok := PublicationIdentity(uri)
		if !ok || authors[did] {
			continue
		}
		value := uri
		scopes = append(scopes, appviewcore.PublicationScope{PublicationID: uri, AuthorDID: did, PublicationATURI: &value, PublicationScopeATURIs: []string{uri}, PublicationSiteURLs: []string{}})
	}
	return scopes
}
func (r *Runtime) ResolvedScopes(ctx context.Context, list List, viewer string) []appviewcore.PublicationScope {
	r.mu.Lock()
	revision := r.siteRevision
	missing := []string{}
	for _, uri := range list.Publications {
		if !r.sites[uri].expires.After(r.Now()) {
			missing = append(missing, uri)
		}
	}
	r.mu.Unlock()
	type result struct {
		uri         string
		publication *PublicationRead
	}
	for start := 0; start < len(missing); start += 5 {
		batch := missing[start:min(start+5, len(missing))]
		results := make(chan result, len(batch))
		var wg sync.WaitGroup
		for _, uri := range batch {
			wg.Add(1)
			go func(uri string) {
				defer wg.Done()
				value, _ := r.Service.Reader.Publication(ctx, uri)
				results <- result{uri, value}
			}(uri)
		}
		wg.Wait()
		close(results)
		r.mu.Lock()
		if revision == r.siteRevision {
			for value := range results {
				var site *string
				if value.publication != nil {
					site = value.publication.SiteURL
					if value.publication.Details != nil {
						r.details[value.uri] = *value.publication.Details
					}
				}
				ttl := time.Minute
				if site != nil {
					ttl = time.Hour
				}
				r.sites[value.uri] = siteValue{site, r.Now().Add(ttl)}
			}
		}
		r.mu.Unlock()
		if ctx.Err() != nil {
			break
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.sites) > 2000 {
		for key, value := range r.sites {
			if !value.expires.After(r.Now()) {
				delete(r.sites, key)
			}
		}
	}
	for key := range r.details {
		if _, ok := r.sites[key]; !ok {
			delete(r.details, key)
		}
	}
	scopes := ListScopes(list)
	for i := range scopes {
		if scopes[i].PublicationATURI != nil {
			if value, ok := r.sites[*scopes[i].PublicationATURI]; ok && value.url != nil {
				scopes[i].PublicationSiteURLs = []string{*value.url}
			}
		}
	}
	return scopes
}
func (r *Runtime) Enrich(_ context.Context, viewer string, list List) List {
	r.mu.Lock()
	details := map[string]Publication{}
	for _, uri := range list.Publications {
		if r.sites[uri].expires.After(r.Now()) {
			if value, ok := r.details[uri]; ok {
				details[uri] = value
			}
		}
	}
	r.mu.Unlock()
	if r.Publication != nil {
		rows := r.Publication.SidebarRows(viewer, list.Publications)
		for _, uri := range list.Publications {
			for _, row := range rows {
				if publicationcore.IDsMatch(row.PublicationID, uri) {
					details[uri] = Publication{PublicationID: uri, Title: row.Title, AuthorDID: row.AuthorDID, AuthorHandle: row.AuthorHandle, IconURL: row.IconURL, AvatarURL: row.AvatarURL}
					break
				}
			}
		}
	}
	values := []Publication{}
	for _, uri := range list.Publications {
		if value, ok := details[uri]; ok {
			values = append(values, value)
		}
	}
	list.PublicationDetails = &values
	return list
}
