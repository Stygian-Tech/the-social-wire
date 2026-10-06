package thinappviewcore

import (
	"io"
	"net/url"
	"strings"

	"golang.org/x/net/html"
)

func NormalizeFeedURL(raw string) *string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return nil
	}
	lower := strings.ToLower(value)
	if !strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://") {
		value = "https://" + value
	}
	u, err := url.Parse(value)
	if err != nil || u.Hostname() == "" || !strings.EqualFold(u.Scheme, "http") && !strings.EqualFold(u.Scheme, "https") {
		return nil
	}
	if strings.EqualFold(u.Scheme, "http") {
		u.Scheme = "https"
	}
	u.Fragment = ""
	u.RawFragment = ""
	u.User = nil
	value = u.String()
	if strings.HasSuffix(value, "/") {
		value = strings.TrimSuffix(value, "/")
	}
	return &value
}
func NormalizeThumbnailURL(raw string, base *string) *string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return nil
	}
	if !strings.HasPrefix(strings.ToLower(value), "http") && base != nil {
		relative, e := url.Parse(value)
		parent, e2 := url.Parse(*base)
		if e == nil && e2 == nil {
			value = parent.ResolveReference(relative).String()
		}
	}
	if !strings.HasPrefix(strings.ToLower(value), "http") {
		return nil
	}
	return NormalizeFeedURL(value)
}
func AcceptsMediaURL(raw string, mediaType, medium *string) bool {
	if strings.TrimSpace(raw) == "" {
		return false
	}
	if mediaType != nil && strings.HasPrefix(strings.ToLower(strings.TrimSpace(*mediaType)), "image/") {
		return true
	}
	if medium != nil && strings.EqualFold(strings.TrimSpace(*medium), "image") {
		return true
	}
	if mediaType != nil || medium != nil {
		return false
	}
	lower := strings.ToLower(raw)
	if strings.Contains(lower, "gravatar.com/avatar") {
		return true
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	path := strings.ToLower(u.Path)
	for _, extension := range []string{".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".bmp"} {
		if strings.HasSuffix(path, extension) || strings.Contains(path, extension+"?") {
			return true
		}
	}
	return false
}

func FirstImageURL(document string) *string {
	tokens := html.NewTokenizer(strings.NewReader(document))
	var openGraph *string
	for {
		switch tokens.Next() {
		case html.ErrorToken:
			if tokens.Err() == io.EOF {
				return openGraph
			}
			return nil
		case html.StartTagToken, html.SelfClosingTagToken:
			token := tokens.Token()
			if token.Data != "img" && token.Data != "meta" {
				continue
			}
			attributes := map[string]string{}
			for _, attr := range token.Attr {
				if _, exists := attributes[attr.Key]; !exists {
					attributes[attr.Key] = attr.Val
				}
			}
			if token.Data == "img" {
				if value := strings.TrimSpace(attributes["src"]); value != "" {
					return &value
				}
			} else if openGraph == nil && strings.EqualFold(attributes["property"], "og:image") {
				if value := strings.TrimSpace(attributes["content"]); value != "" {
					openGraph = &value
				}
			}
		}
	}
}
func ResolveThumbnail(storedURL, contentHTML, summary string, articleLink, feedURL *string) *string {
	base := articleLink
	if base == nil {
		base = feedURL
	}
	if stored := NormalizeThumbnailURL(storedURL, base); stored != nil {
		return stored
	}
	for _, html := range []string{contentHTML, summary} {
		if image := FirstImageURL(html); image != nil {
			if normalized := NormalizeThumbnailURL(*image, base); normalized != nil {
				return normalized
			}
		}
	}
	return nil
}
