package publicationcore

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"golang.org/x/net/html"
)

var ErrArticleNotFound = errors.New("verified article not found")
var ErrArticleURL = errors.New("invalid article URL")

type ArticleEmbed struct {
	DocumentURI     string `json:"documentUri"`
	PublicationURI  string `json:"publicationUri"`
	PublicationName string `json:"publicationName"`
	PublicationURL  string `json:"publicationUrl"`
	ArticleURL      string `json:"articleUrl"`
	Title           string `json:"title"`
	Description     string `json:"description,omitempty"`
	AuthorDID       string `json:"authorDid"`
}
type cachedArticle struct {
	value   ArticleEmbed
	expires time.Time
}
type ArticleResolver struct {
	Repo      Repository
	HTTP      thinappviewcore.PublicGetter
	mu        sync.Mutex
	cache     map[string]cachedArticle
	admission chan struct{}
}

func NewArticleResolver(repo Repository, getter thinappviewcore.PublicGetter) *ArticleResolver {
	return &ArticleResolver{Repo: repo, HTTP: getter, cache: map[string]cachedArticle{}, admission: make(chan struct{}, 16)}
}
func articleURL(raw string) (*url.URL, error) {
	u, e := url.Parse(raw)
	if e != nil || len(raw) > 4096 || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		return nil, ErrArticleURL
	}
	u.Fragment = ""
	return u, nil
}

// Resolve only promotes links whose declared public record maps back to the requested URL.
// Failed lookups are not cached; each call has a fresh deadline and bounded admission.
func (r *ArticleResolver) Resolve(ctx context.Context, raw string) (*ArticleEmbed, error) {
	page, e := articleURL(raw)
	if e != nil {
		return nil, e
	}
	key := page.String()
	r.mu.Lock()
	cached, ok := r.cache[key]
	r.mu.Unlock()
	if ok && cached.expires.After(time.Now()) {
		result := cached.value
		return &result, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	select {
	case r.admission <- struct{}{}:
		defer func() { <-r.admission }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	status, _, body, e := r.HTTP.Get(ctx, key, http.Header{"Accept": {"text/html"}}, 1<<20, 3)
	if e != nil {
		return nil, e
	}
	if status == 404 {
		return nil, ErrArticleNotFound
	}
	if status != 200 {
		return nil, errors.New("article source unavailable")
	}
	uri := articleHeadURI(string(body))
	did, col, rkey, ok := parseURI(uri)
	if !ok || !strings.HasPrefix(did, "did:") {
		return nil, ErrArticleNotFound
	}
	record, e := r.Repo.GetRecord(ctx, did, col, rkey, "")
	if e != nil {
		return nil, e
	}
	if record == nil || record.URI != uri {
		return nil, ErrArticleNotFound
	}
	doc := recordValue(*record)
	if text(doc, "$type") != col {
		return nil, ErrArticleNotFound
	}
	pubURI := text(doc, "site")
	pdid, pcol, pkey, ok := parseURI(pubURI)
	if !ok || pcol != "site.standard.publication" || !strings.HasPrefix(pdid, "did:") {
		return nil, ErrArticleNotFound
	}
	pub, e := r.Repo.GetRecord(ctx, pdid, pcol, pkey, "")
	if e != nil {
		return nil, e
	}
	if pub == nil || pub.URI != pubURI {
		return nil, ErrArticleNotFound
	}
	publication := recordValue(*pub)
	if text(publication, "$type") != pcol {
		return nil, ErrArticleNotFound
	}
	base, e := articleURL(text(publication, "url"))
	if e != nil {
		return nil, ErrArticleNotFound
	}
	path := text(doc, "path")
	if !strings.HasPrefix(path, "/") || strings.HasPrefix(path, "//") {
		return nil, ErrArticleNotFound
	}
	// Standard.site paths append to the publication URL (which may include a path).
	canonical, e := articleURL(strings.TrimRight(base.String(), "/") + path)
	if e != nil || canonical.String() != key || canonical.Host != base.Host {
		return nil, ErrArticleNotFound
	}
	result := ArticleEmbed{DocumentURI: uri, PublicationURI: pubURI, PublicationName: text(publication, "name"), PublicationURL: base.String(), ArticleURL: key, Title: text(doc, "title"), Description: text(doc, "description"), AuthorDID: did}
	if result.Title == "" || result.PublicationName == "" {
		return nil, ErrArticleNotFound
	}
	r.mu.Lock()
	if len(r.cache) >= 256 {
		clear(r.cache)
	}
	r.cache[key] = cachedArticle{result, time.Now().Add(5 * time.Minute)}
	r.mu.Unlock()
	return &result, nil
}
func articleHeadURI(body string) string {
	z := html.NewTokenizer(strings.NewReader(body))
	inHead := false
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			return ""
		}
		if tt != html.StartTagToken && tt != html.SelfClosingTagToken && tt != html.EndTagToken {
			continue
		}
		t := z.Token()
		if t.Data == "head" {
			if tt == html.EndTagToken {
				return ""
			}
			inHead = true
			continue
		}
		if t.Data == "body" {
			return ""
		}
		if !inHead || tt == html.EndTagToken {
			continue
		}
		attrs := map[string]string{}
		for _, a := range t.Attr {
			attrs[a.Key] = a.Val
		}
		candidate := ""
		if t.Data == "meta" && (strings.EqualFold(attrs["name"], "at:canonical") || strings.EqualFold(attrs["property"], "at:canonical")) {
			candidate = attrs["content"]
		}
		if t.Data == "link" {
			for _, rel := range strings.Fields(attrs["rel"]) {
				if rel == "site.standard.document" || rel == "site.standard.entry" {
					candidate = attrs["href"]
				}
			}
		}
		_, col, _, ok := parseURI(candidate)
		if ok && (col == "site.standard.document" || col == "site.standard.entry") {
			return candidate
		}
	}
}
