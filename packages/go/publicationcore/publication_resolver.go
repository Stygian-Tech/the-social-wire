package publicationcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

type ResolveResult struct {
	Kind             string  `json:"kind"`
	PublicationATURI *string `json:"publicationAtUri,omitempty"`
	FeedURL          *string `json:"feedUrl,omitempty"`
	SiteURL          *string `json:"siteUrl,omitempty"`
}
type ResolveResponse struct {
	Result *ResolveResult `json:"result,omitempty"`
	Error  *string        `json:"error,omitempty"`
}
type Resolver struct {
	Repo Repository
	HTTP thinappviewcore.PublicGetter
}

func resolveError(message string) ResolveResponse { return ResolveResponse{Error: &message} }
func standard(uri string) ResolveResponse {
	return ResolveResponse{Result: &ResolveResult{Kind: "standard-site", PublicationATURI: &uri}}
}
func (r Resolver) Resolve(ctx context.Context, raw string) ResolveResponse {
	input := strings.TrimSpace(raw)
	if input == "" {
		return resolveError("Enter a link or publication reference.")
	}
	candidate := NormalizeATRepoParam(input)
	if strings.HasPrefix(candidate, "at://") {
		return r.atURI(ctx, candidate)
	}
	if strings.Contains(input, "://") {
		return r.https(ctx, input)
	}
	if did, e := r.Repo.ResolveDID(ctx, input); e == nil && did != "" {
		for _, col := range []string{"site.standard.publication", "com.standard.publication", "app.offprint.publication"} {
			page, e := r.Repo.ListRecords(ctx, did, col, "", 1, true)
			if e == nil && len(page.Records) > 0 {
				return standard(page.Records[0].URI)
			}
		}
	}
	if strings.HasPrefix(input, "did:") {
		return resolveError("No site.standard.publication (or com.standard.publication) records found for that DID.")
	}
	return r.https(ctx, "https://"+input)
}
func (r Resolver) atURI(ctx context.Context, uri string) ResolveResponse {
	did, col, key, ok := parseURI(uri)
	if !ok {
		return resolveError("Invalid AT-URI.")
	}
	if col == "app.offprint.publication" {
		if record, e := r.Repo.GetRecord(ctx, did, col, key, ""); e == nil && record != nil {
			if inner := text(recordValue(*record), "publication"); inner != "" {
				return standard(NormalizeATRepoParam(inner))
			}
		}
		return resolveError("Offprint publication record is missing its site.standard.publication reference.")
	}
	if col == "site.standard.publication" || col == "com.standard.publication" {
		return standard(uri)
	}
	return resolveError("Unsupported AT-URI — use a publication record (site.standard.publication or com.standard.publication).")
}
func (r Resolver) get(ctx context.Context, target, accept string, max int) (int, []byte) {
	getter := r.HTTP
	if getter == nil {
		getter = thinappviewcore.PublicHTTP{}
	}
	work, cancel := context.WithTimeout(ctx, 14*time.Second)
	defer cancel()
	status, _, body, e := getter.Get(work, target, http.Header{"Accept": {accept}, "User-Agent": {"the-social-wire/resolve-publication"}}, max, 5)
	if e != nil {
		return 0, nil
	}
	return status, body
}
func (r Resolver) https(ctx context.Context, input string) ResolveResponse {
	normalized := thinappviewcore.NormalizeFeedURL(input)
	if normalized == nil {
		return resolveError("invalid url")
	}
	page, e := url.Parse(*normalized)
	if e != nil || page.Scheme != "https" || page.User != nil {
		return resolveError("invalid url")
	}
	origin := *page
	origin.Path = ""
	origin.RawPath = ""
	origin.RawQuery = ""
	origin.Fragment = ""
	originURL := origin.String()
	work, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan *ResolveResult, 2)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		status, body := r.get(work, strings.TrimRight(originURL, "/")+"/.well-known/site.standard.publication", "text/plain, application/json", 4096)
		if status == 200 {
			tokens := strings.Fields(string(body))
			if len(tokens) > 0 {
				uri := NormalizeATRepoParam(tokens[0])
				_, col, _, ok := parseURI(uri)
				if ok && (col == "site.standard.publication" || col == "com.standard.publication" || col == "app.offprint.publication") {
					results <- &ResolveResult{Kind: "standard-site", PublicationATURI: &uri}
					return
				}
			}
		}
		results <- nil
	}()
	go func() {
		defer wg.Done()
		feed := r.discoverRSS(work, page)
		if feed != "" {
			results <- &ResolveResult{Kind: "rss", FeedURL: &feed, SiteURL: &originURL}
		} else {
			results <- nil
		}
	}()
	var chosen *ResolveResult
	for i := 0; i < 2; i++ {
		result := <-results
		if result != nil && chosen == nil {
			chosen = result
			cancel()
		}
	}
	wg.Wait()
	if chosen != nil {
		return ResolveResponse{Result: chosen}
	}
	return resolveError("Could not find a standard.site publication marker for this domain or a reachable RSS/Atom feed. Try a publication AT-URI or a direct feed URL.")
}
func feedBody(body []byte) bool {
	lower := strings.ToLower(string(body))
	return strings.Contains(lower, "<rss") || strings.Contains(lower, "<feed") || strings.Contains(lower, "<channel")
}

var linkTag = regexp.MustCompile(`(?i)<link\b[^>]*>`)
var hrefAttribute = regexp.MustCompile(`(?i)\bhref\s*=\s*["']([^"']+)["']`)

func alternateFeeds(html string, base *url.URL) []string {
	out := []string{}
	for _, tag := range linkTag.FindAllString(html, -1) {
		lower := strings.ToLower(tag)
		if !strings.Contains(lower, `rel="alternate"`) && !strings.Contains(lower, `rel='alternate'`) {
			continue
		}
		match := hrefAttribute.FindStringSubmatch(lower)
		if len(match) != 2 {
			continue
		}
		if href, e := url.Parse(match[1]); e == nil {
			out = append(out, base.ResolveReference(href).String())
		}
	}
	return out
}
func (r Resolver) discoverRSS(ctx context.Context, page *url.URL) string {
	status, body := r.get(ctx, page.String(), "text/html,application/xhtml+xml,application/xml", 1024*1024)
	if status != 200 {
		return ""
	}
	if feedBody(body) {
		return page.String()
	}
	candidates := alternateFeeds(string(body), page)
	for _, path := range []string{"/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/feeds/rss"} {
		u, _ := url.Parse(path)
		candidates = append(candidates, page.ResolveReference(u).String())
	}

	unique := []string{}
	seen := map[string]bool{}
	for _, raw := range candidates {
		if feed := thinappviewcore.NormalizeFeedURL(raw); feed != nil && !seen[*feed] {
			seen[*feed] = true
			unique = append(unique, *feed)
		}
	}
	work, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan string, 8)
	next, active := 0, 0
	launch := func(feed string) {
		active++
		go func() {
			status, body := r.get(work, feed, "application/rss+xml, application/atom+xml, application/xml, text/xml, */*", 512*1024)
			if (status == 200 || status == 403 || status == 406 || status == 415) && feedBody(body) {
				results <- feed
			} else {
				results <- ""
			}
		}()
	}
	for next < len(unique) && active < 8 && work.Err() == nil {
		launch(unique[next])
		next++
	}
	found := ""
	for active > 0 {
		feed := <-results
		active--
		if feed != "" && found == "" {
			found = feed
			cancel()
		}
		if found == "" && next < len(unique) && work.Err() == nil {
			launch(unique[next])
			next++
		}
	}
	return found
}
