package analyticscore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Repository interface {
	ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error)
	GetRecord(context.Context, string, string, string, string) (*gatewaycore.RepoRecord, error)
}
type Provider struct {
	Repo    Repository
	HTTP    *http.Client
	AppView string
}

func parseSubject(uri string) (string, string, string, error) {
	if !strings.HasPrefix(uri, "at://") || len(uri) > 2048 || strings.ContainsAny(uri, "?#@\\ \r\n\t") {
		return "", "", "", errors.New("invalid subject")
	}
	parts := strings.Split(strings.TrimPrefix(uri, "at://"), "/")
	if len(parts) != 3 || !strings.HasPrefix(parts[0], "did:") || parts[2] == "" || strings.Contains(parts[2], "%") || parts[2] == "." || parts[2] == ".." || len(parts[2]) > 512 || len(strings.SplitN(parts[0], ":", 3)) != 3 || strings.SplitN(parts[0], ":", 3)[2] == "" {
		return "", "", "", errors.New("invalid subject")
	}
	return parts[0], parts[1], parts[2], nil
}
func Subject(uri string) (string, string, string, error) {
	d, c, k, e := parseSubject(uri)
	if e != nil {
		return "", "", "", e
	}
	if c != "app.bsky.feed.post" && c != "site.standard.document" {
		return "", "", "", errors.New("unsupported subject")
	}
	return d, c, k, nil
}
func (p Provider) Validate(ctx context.Context, uri string) error {
	d, c, k, e := Subject(uri)
	if e != nil {
		return e
	}
	r, e := p.Repo.GetRecord(ctx, d, c, k, "")
	if e != nil {
		return e
	}
	if r == nil || r.URI != uri || stringValue(r.Value, "$type") != c {
		return errors.New("invalid canonical subject")
	}
	return nil
}
func stringValue(m map[string]json.RawMessage, k string) string {
	var s string
	_ = json.Unmarshal(m[k], &s)
	return s
}

// Reads public records using the same policy-bound transport as all public PDS reads.
func (p Provider) Inventory(ctx context.Context, did string, now time.Time) ([]Item, bool, error) {
	items := []Item{}
	complete := true
	publications := map[string]*gatewaycore.RepoRecord{}
	for _, collection := range []string{"app.bsky.feed.post", "site.standard.document"} {
		records := []gatewaycore.RepoRecord{}
		cursor := ""
		seen := map[string]bool{}
		identities := map[string]bool{}
		for pageNumber := 0; pageNumber < 10; pageNumber++ {
			page, e := p.Repo.ListRecords(ctx, did, collection, cursor, 100, true)
			if e != nil {
				return nil, false, e
			}
			if len(page.Records) > 100 {
				return nil, false, errors.New("inventory page exceeded limit")
			}
			for _, r := range page.Records {
				if identities[r.URI] {
					return nil, false, errors.New("duplicate inventory subject")
				}
				identities[r.URI] = true
				records = append(records, r)
			}
			if page.Cursor == "" {
				cursor = ""
				break
			}
			if seen[page.Cursor] {
				return nil, false, errors.New("repeated inventory cursor")
			}
			seen[page.Cursor] = true
			cursor = page.Cursor
		}
		if cursor != "" {
			complete = false
		}
		for _, r := range records {
			d, c, _, e := Subject(r.URI)
			if e != nil || d != did || c != collection || stringValue(r.Value, "$type") != collection {
				return nil, false, errors.New("invalid owned inventory")
			}
			kind, title, date := "post", stringValue(r.Value, "text"), stringValue(r.Value, "createdAt")
			link := fmt.Sprintf("https://bsky.app/profile/%s/post/%s", did, strings.Split(r.URI, "/")[4])
			if collection == "site.standard.document" {
				kind, title, date = "article", stringValue(r.Value, "title"), stringValue(r.Value, "publishedAt")
				link = ""
				site := stringValue(r.Value, "site")
				sd, sc, sk, e := publicationSubject(site)
				if e == nil && sd == did {
					pub, known := publications[site]
					var e error
					if !known && len(publications) < 25 {
						pub, e = p.Repo.GetRecord(ctx, sd, sc, sk, "")
						publications[site] = pub
					}
					if e == nil && pub != nil && pub.URI == site && stringValue(pub.Value, "$type") == "site.standard.publication" {
						base := stringValue(pub.Value, "url")
						b, e := url.Parse(base)
						path := stringValue(r.Value, "path")
						if e == nil && b.Scheme == "https" && b.Host != "" && b.User == nil && strings.HasPrefix(path, "/") && !strings.HasPrefix(path, "//") {
							b.Path = strings.TrimRight(b.Path, "/") + path
							b.RawQuery = ""
							b.Fragment = ""
							link = b.String()
						}
					}
				}
			}
			items = append(items, Item{URI: r.URI, Kind: kind, Title: title, URL: link, PublishedAt: date, RefreshedAt: now})
		}
	}
	for start := 0; start < len(items); start += 25 {
		uris := []string{}
		for _, it := range items[start:min(start+25, len(items))] {
			if it.Kind == "post" {
				uris = append(uris, it.URI)
			}
		}
		if len(uris) == 0 {
			continue
		}
		q := url.Values{"uris": uris}
		req, e := http.NewRequestWithContext(ctx, "GET", strings.TrimRight(p.AppView, "/")+"/xrpc/app.bsky.feed.getPosts?"+q.Encode(), nil)
		if e != nil {
			return nil, false, e
		}
		resp, e := p.HTTP.Do(req)
		if e != nil {
			return nil, false, e
		}
		body, e := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024+1))
		resp.Body.Close()
		if e != nil || resp.StatusCode != 200 || len(body) > 2*1024*1024 {
			return nil, false, errors.New("engagement provider unavailable")
		}
		var data struct {
			Posts []struct {
				URI    string `json:"uri"`
				Author struct {
					DID string `json:"did"`
				} `json:"author"`
				Likes   *int `json:"likeCount"`
				Replies *int `json:"replyCount"`
				Reposts *int `json:"repostCount"`
				Quotes  *int `json:"quoteCount"`
			} `json:"posts"`
		}
		if json.Unmarshal(body, &data) != nil {
			return nil, false, errors.New("invalid engagement response")
		}
		for _, post := range data.Posts {
			if post.Author.DID != did {
				return nil, false, errors.New("engagement author mismatch")
			}
			for i := range items {
				if items[i].URI == post.URI && post.Likes != nil && post.Replies != nil && post.Reposts != nil && post.Quotes != nil {
					if min(*post.Likes, *post.Replies, *post.Reposts, *post.Quotes) < 0 {
						return nil, false, errors.New("negative engagement")
					}
					items[i].Engagement = &Engagement{*post.Likes, *post.Replies, *post.Reposts, *post.Quotes}
				}
			}
		}
	}
	return items, complete, nil
}
func publicationSubject(uri string) (string, string, string, error) {
	d, c, k, e := parseSubject(uri)
	if e != nil || c != "site.standard.publication" {
		return "", "", "", errors.New("invalid publication")
	}
	return d, c, k, nil
}
