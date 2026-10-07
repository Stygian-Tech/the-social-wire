package thinappviewcore

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"strings"
	"unicode"
)

const RSSAuthorDID = "did:web:skyreader.rss"
const RSSSubscriptionCollection = "app.skyreader.feed.subscription"
const RSSEntryCollection = "app.skyreader.feed.entry"

func RSSPublicationID(feed string) string {
	return "rss:" + base64.RawURLEncoding.EncodeToString([]byte(feed))
}
func RSSEntryID(feed, key string) string {
	inner, _ := json.Marshal(struct {
		Feed string `json:"f"`
		Key  string `json:"k"`
	}{feed, key})
	return "rssentry:" + base64.RawURLEncoding.EncodeToString(inner)
}
func RSSDeterministicCID(uri string) string {
	hash := sha256.Sum256([]byte(uri))
	return "rss:" + hex.EncodeToString(hash[:16])
}
func rssPostIdentity(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	digits := func(s string) bool {
		return s != "" && strings.IndexFunc(s, func(r rune) bool { return !unicode.IsNumber(r) }) < 0
	}
	if post := u.Query().Get("p"); digits(post) {
		return "post:" + host + ":" + post
	}
	for _, segment := range strings.Split(u.Path, "/") {
		if len([]rune(segment)) >= 5 && digits(segment) {
			return "post:" + host + ":" + segment
		}
	}
	return ""
}
func RSSStableItemKey(item ParsedRSSItem) string {
	for _, value := range []*string{item.Link, item.GUID} {
		if value != nil {
			if key := rssPostIdentity(*value); key != "" {
				return key
			}
		}
	}
	for index, value := range []*string{item.Link, item.GUID} {
		if value != nil && strings.TrimSpace(*value) != "" {
			raw := strings.TrimSpace(*value)
			if normalized := NormalizeFeedURL(raw); normalized != nil {
				raw = *normalized
			}
			prefix := "link:"
			if index == 1 {
				prefix = "guid:"
			}
			return prefix + raw
		}
	}
	return "fallback:" + strings.TrimSpace(item.Title) + "\n" + strings.TrimSpace(item.PublishedAtISO)
}
func DecodeRSSEntryID(uri string) (feed, key string) {
	if !strings.HasPrefix(uri, "rssentry:") {
		return "", ""
	}
	data, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(uri, "rssentry:"))
	if err != nil {
		return "", ""
	}
	var inner struct {
		Feed string `json:"f"`
		Key  string `json:"k"`
	}
	if json.Unmarshal(data, &inner) == nil && inner.Feed != "" && inner.Key != "" {
		return inner.Feed, inner.Key
	}
	parts := strings.SplitN(string(data), "|", 2)
	if len(parts) == 2 {
		return parts[0], parts[1]
	}
	return "", ""
}
func RSSCanonicalArticleURL(raw string) string {
	if normalized := NormalizePublicationSiteURL(raw); normalized != "" {
		return normalized
	}
	if normalized := NormalizeFeedURL(raw); normalized != nil {
		return *normalized
	}
	return ""
}
func RSSDedupeKeys(uri string, render ContentRenderFields) []string {
	keys := map[string]bool{}
	_, stable := DecodeRSSEntryID(uri)
	if strings.HasPrefix(stable, "post:") {
		keys[stable] = true
	}
	raw := ""
	for _, prefix := range []string{"link:", "guid:"} {
		if strings.HasPrefix(stable, prefix) {
			raw = strings.TrimPrefix(stable, prefix)
		}
	}
	if raw != "" {
		if key := rssPostIdentity(raw); key != "" {
			keys[key] = true
		}
		if canonical := RSSCanonicalArticleURL(raw); canonical != "" {
			keys["url:"+canonical] = true
		}
	}
	if render.ArticleURL != nil {
		if canonical := RSSCanonicalArticleURL(*render.ArticleURL); canonical != "" {
			keys["url:"+canonical] = true
		}
		if key := rssPostIdentity(*render.ArticleURL); key != "" {
			keys[key] = true
		}
	}
	result := []string{}
	for key := range keys {
		result = append(result, key)
	}
	return result
}
