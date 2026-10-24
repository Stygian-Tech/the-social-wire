package publicationcore

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

const articleURI = "at://did:plc:author/site.standard.document/post"
const publicationURI = "at://did:plc:author/site.standard.publication/pub"

func TestArticleHeadDiscovery(t *testing.T) {
	for _, tc := range []struct{ html, want string }{
		{`<head><meta name="at:alternate" content="` + publicationURI + `"><meta name="at:canonical" content="` + articleURI + `"></head>`, articleURI},
		{`<head><link rel="alternate site.standard.document" href="` + articleURI + `"></head>`, articleURI},
		{`<head><meta name="at:canonical" content="` + publicationURI + `"></head>`, ""},
		{`<head></head><body><link rel="site.standard.document" href="` + articleURI + `">`, ""},
		{`<head><link rel="alternate" href="` + articleURI + `"></head>`, ""},
		{`<head><script>'<meta name="at:canonical" content="` + articleURI + `">'</script></head>`, ""},
	} {
		if got := articleHeadURI(tc.html); got != tc.want {
			t.Fatalf("%s: %s", tc.html, got)
		}
	}
}
func TestArticleVerificationAndRetry(t *testing.T) {
	repo := repoFixture{records: map[string]gatewaycore.RepoRecord{
		articleURI:     record(articleURI, map[string]any{"$type": "site.standard.document", "site": publicationURI, "path": "/post", "title": "Article"}),
		publicationURI: record(publicationURI, map[string]any{"$type": "site.standard.publication", "url": "https://publisher.social", "name": "Publication"}),
	}}
	calls := 0
	getter := getterFunc(func(ctx context.Context, _ string, _ http.Header, max, redirects int) (int, http.Header, []byte, error) {
		calls++
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("missing request deadline")
		}
		if max != 1<<20 || redirects != 3 {
			t.Fatal("unbounded fetch")
		}
		if calls == 1 {
			return 0, nil, nil, errors.New("temporary failure")
		}
		return 200, nil, []byte(`<head><meta name="at:canonical" content="` + articleURI + `"></head>`), nil
	})
	resolver := NewArticleResolver(repo, getter)
	if _, err := resolver.Resolve(context.Background(), "https://publisher.social/post"); err == nil {
		t.Fatal("wanted temporary error")
	}
	result, err := resolver.Resolve(context.Background(), "https://publisher.social/post")
	if err != nil || result.DocumentURI != articleURI || result.PublicationURI != publicationURI {
		t.Fatalf("%+v %v", result, err)
	}
	resolver.Resolve(context.Background(), "https://publisher.social/post")
	if calls != 2 {
		t.Fatal("success not cached")
	}
	resolver.cache["https://publisher.social/post"] = cachedArticle{*result, time.Now().Add(-time.Second)}
	resolver.Resolve(context.Background(), "https://publisher.social/post")
	if calls != 3 {
		t.Fatal("expired success not refreshed")
	}
	if _, err := resolver.Resolve(context.Background(), "https://attacker.social/post"); !errors.Is(err, ErrArticleNotFound) {
		t.Fatalf("unverified backlink: %v", err)
	}
	if _, err := resolver.Resolve(context.Background(), "http://publisher.social/post"); !errors.Is(err, ErrArticleURL) {
		t.Fatal(err)
	}
}

func TestArticlePublicationPathsAndRecordIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, base, path, target string
		invalid                  bool
	}{
		{"root", "https://publisher.social", "/", "https://publisher.social/", false},
		{"publication subpath", "https://publisher.social/blog", "/post", "https://publisher.social/blog/post", false},
		{"protocol relative path", "https://publisher.social", "//attacker.social/post", "https://attacker.social/post", true},
		{"mismatched path", "https://publisher.social", "/different", "https://publisher.social/post", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo := repoFixture{records: map[string]gatewaycore.RepoRecord{
				articleURI:     record(articleURI, map[string]any{"$type": "site.standard.document", "site": publicationURI, "path": tc.path, "title": "Article"}),
				publicationURI: record(publicationURI, map[string]any{"$type": "site.standard.publication", "url": tc.base, "name": "Publication"}),
			}}
			getter := getterFunc(func(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error) {
				return 200, nil, []byte(`<head><link rel="site.standard.document" href="` + articleURI + `"></head>`), nil
			})
			resolver := NewArticleResolver(repo, getter)
			result, err := resolver.Resolve(context.Background(), tc.target)
			if tc.invalid {
				if !errors.Is(err, ErrArticleNotFound) {
					t.Fatalf("%+v %v", result, err)
				}
				return
			}
			if err != nil || result.ArticleURL != tc.target {
				t.Fatalf("%+v %v", result, err)
			}
			for _, uri := range []string{articleURI, publicationURI} {
				r := repo.records[uri]
				r.URI = "at://did:plc:attacker/site.standard.document/wrong"
				repo.records[uri] = r
				if _, err := NewArticleResolver(repo, getter).Resolve(context.Background(), tc.target); !errors.Is(err, ErrArticleNotFound) {
					t.Fatalf("identity mismatch accepted: %v", err)
				}
				r.URI = uri
				repo.records[uri] = r
			}
		})
	}
}
