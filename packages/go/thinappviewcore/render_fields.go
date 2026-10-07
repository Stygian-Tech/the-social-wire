package thinappviewcore

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

type ContentRenderFields struct {
	Title        string  `json:"title"`
	PublishedAt  string  `json:"publishedAt"`
	Summary      *string `json:"summary,omitempty"`
	ThumbnailURL *string `json:"thumbnailUrl,omitempty"`
	ContentHTML  *string `json:"contentHtml,omitempty"`
	ArticleURL   *string `json:"articleUrl,omitempty"`
}
type IndexedContentItem struct {
	URI, CID, AuthorDID, Collection string
	CreatedAt, IndexedAt, ExpiresAt time.Time
	PublicationSite                 *string
	Render                          ContentRenderFields
}

func nonempty(value any) string { s, _ := value.(string); return strings.TrimSpace(s) }
func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

var htmlTagPattern = regexp.MustCompile(`<[^>]+>`)
var htmlEntityPattern = regexp.MustCompile(`&([^;]+);`)
var renderEntities = map[string]string{"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u00a0", "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"}

// DecodeRenderText deliberately keeps unknown named entities, matching Swift.
func DecodeRenderText(raw string) string {
	raw = htmlTagPattern.ReplaceAllString(strings.TrimSpace(raw), "")
	return htmlEntityPattern.ReplaceAllStringFunc(raw, func(entity string) string {
		name := entity[1 : len(entity)-1]
		if decoded, ok := renderEntities[strings.ToLower(name)]; ok {
			return decoded
		}
		if strings.HasPrefix(name, "#") {
			digits := name[1:]
			base := 10
			if len(digits) > 0 && (digits[0] == 'x' || digits[0] == 'X') {
				digits = digits[1:]
				base = 16
			}
			n, err := strconv.ParseInt(digits, base, 32)
			if err == nil && utf8.ValidRune(rune(n)) {
				return string(rune(n))
			}
		}
		return entity
	})
}
func PublicationSiteField(record map[string]any) string {
	for _, key := range []string{"site", "publication", "publicationUri", "publicationId"} {
		if site := nonempty(record[key]); site != "" {
			return site
		}
		if ref, ok := record[key].(map[string]any); ok {
			if site := nonempty(ref["uri"]); site != "" {
				return site
			}
		}
	}
	return ""
}
func NormalizePublicationSiteURL(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (strings.ToLower(u.Scheme) != "http" && strings.ToLower(u.Scheme) != "https") {
		return ""
	}
	u.Fragment = ""
	u.RawQuery = ""
	u.ForceQuery = false
	return strings.TrimSuffix(u.String(), "/")
}
func NormalizeArticleURL(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (strings.ToLower(u.Scheme) != "http" && strings.ToLower(u.Scheme) != "https") {
		return ""
	}
	u.Fragment = ""
	u.Scheme = "https"
	return u.String()
}
func ArticleURL(record map[string]any, publicationBase string) string {
	for _, key := range []string{"url", "externalUrl", "canonicalUrl", "href", "permalink"} {
		if value := NormalizeArticleURL(nonempty(record[key])); value != "" {
			return value
		}
	}
	base := NormalizePublicationSiteURL(PublicationSiteField(record))
	if base == "" {
		base = NormalizePublicationSiteURL(publicationBase)
	}
	path := nonempty(record["path"])
	if base == "" || path == "" {
		return ""
	}
	if value := NormalizeArticleURL(path); value != "" {
		return value
	}
	path = strings.Trim(path, "/")
	if path == "" {
		return base
	}
	return NormalizeArticleURL(base + "/" + path)
}
func ExtractBlobLink(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	if obj, ok := value.(map[string]any); ok {
		if link := nonempty(obj["$link"]); link != "" {
			return link
		}
		if ref, ok := obj["ref"].(map[string]any); ok {
			return nonempty(ref["$link"])
		}
	}
	return ""
}
func BuildSyncGetBlobURL(pds, did, cid string) string {
	if pds == "" {
		return ""
	}
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(pds), "/") + "/xrpc/com.atproto.sync.getBlob")
	if err != nil {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	if host == "atproto.brid.gy" || strings.HasSuffix(host, ".brid.gy") {
		return ""
	}
	u.RawQuery = "did=" + url.QueryEscape(did) + "&cid=" + url.QueryEscape(cid)
	return u.String()
}
func httpImage(value string) string {
	if strings.HasPrefix(strings.ToLower(value), "http://") || strings.HasPrefix(strings.ToLower(value), "https://") {
		return value
	}
	return ""
}
func ExtractRenderFields(record map[string]any, did, pds string, now time.Time) ContentRenderFields {
	title := nonempty(record["title"])
	if title == "" {
		title = nonempty(record["name"])
	}
	if title == "" {
		parts := strings.FieldsFunc(nonempty(record["path"]), func(r rune) bool { return r == '/' })
		if len(parts) > 0 {
			title = parts[len(parts)-1]
		}
	}
	if title == "" {
		title = "Untitled"
	}
	title = DecodeRenderText(title)
	published := nonempty(record["publishedAt"])
	if published == "" {
		published = nonempty(record["createdAt"])
	}
	if published == "" {
		published = nonempty(record["indexedAt"])
	}
	if published == "" {
		published = now.UTC().Format(time.RFC3339)
	}
	summary := nonempty(record["summary"])
	if summary == "" {
		summary = nonempty(record["description"])
	}
	thumbnail := ""
	for _, key := range []string{"thumbnailUrl", "coverImageUrl", "image", "heroImage", "socialImage", "coverImage", "thumbnail"} {
		if thumbnail = httpImage(nonempty(record[key])); thumbnail != "" {
			break
		}
	}
	if thumbnail == "" {
		for _, key := range []string{"coverImage", "thumbnail", "image", "heroImage", "socialImage"} {
			thumbnail = httpImage(nonempty(record[key]))
			if thumbnail == "" && did != "" {
				if cid := ExtractBlobLink(record[key]); cid != "" {
					thumbnail = BuildSyncGetBlobURL(pds, did, cid)
				}
			}
			if thumbnail != "" {
				break
			}
		}
	}
	return ContentRenderFields{Title: title, PublishedAt: published, Summary: optional(DecodeRenderText(summary)), ThumbnailURL: optional(thumbnail), ArticleURL: optional(ArticleURL(record, ""))}
}

func CanonicalPublicationATURI(raw string) string {
	if !strings.HasPrefix(raw, "at://") {
		return ""
	}
	parts := strings.Split(strings.TrimPrefix(raw, "at://"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return ""
	}
	if strings.HasPrefix(strings.ToLower(parts[0]), "did:plc:") {
		parts[0] = strings.ToLower(parts[0])
	}
	return "at://" + strings.Join(parts, "/")
}
func PublicationEquivalenceKeys(raw string) []string {
	canonical := CanonicalPublicationATURI(raw)
	if canonical == "" {
		return nil
	}
	keys := []string{canonical}
	if strings.Contains(canonical, "/site.standard.publication/") {
		keys = append(keys, strings.Replace(canonical, "/site.standard.publication/", "/com.standard.publication/", 1))
	} else if strings.Contains(canonical, "/com.standard.publication/") {
		keys = append(keys, strings.Replace(canonical, "/com.standard.publication/", "/site.standard.publication/", 1))
	}
	return keys
}
func MatchesPublication(site, primary string, scopes, sites []string) bool {
	if primary == "" && len(scopes) == 0 && len(sites) == 0 {
		return true
	}
	if site == "" {
		return false
	}
	keys := PublicationEquivalenceKeys(primary)
	for _, scope := range scopes {
		if key := CanonicalPublicationATURI(scope); key != "" {
			keys = append(keys, key)
		}
	}
	if actual := CanonicalPublicationATURI(site); actual != "" {
		for _, key := range keys {
			if actual == key {
				return true
			}
		}
	}
	hasQuery := false
	for _, want := range sites {
		if normalized := NormalizeFeedURL(want); normalized != nil {
			if actual := NormalizeFeedURL(site); actual != nil && *actual == *normalized {
				return true
			}
			u, _ := url.Parse(*normalized)
			hasQuery = hasQuery || u.RawQuery != ""
		}
	}
	if hasQuery && NormalizeFeedURL(site) != nil {
		return false
	}
	actual := NormalizePublicationSiteURL(site)
	if actual != "" {
		for _, want := range sites {
			if NormalizePublicationSiteURL(want) == actual {
				return true
			}
		}
	}
	return false
}
