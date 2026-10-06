package thinappviewcore

// Normalizes feed/image URLs and discovers thumbnails from explicit media, article HTML,
// and summary HTML. The HTML tokenizer ignores comment/script text and decodes attributes.
// URL normalization is not a DNS, redirect, or fetch authorization check.

import (
	"io"
	"net/url"
	"strings"

	"golang.org/x/net/html"
)

// NormalizeFeedURL normalizes HTTP(S) input to HTTPS without credentials, fragments, or a
// trailing slash; it does not authorize fetching.
func NormalizeFeedURL(raw string) *string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return nil
	}
	lower := strings.ToLower(value)
	if !strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://") {
		value = "https://" + value
	}
	uRL, err := url.Parse(value)
	if err != nil || uRL.Hostname() == "" || !strings.EqualFold(uRL.Scheme, "http") && !strings.EqualFold(uRL.Scheme, "https") {
		return nil
	}
	if strings.EqualFold(uRL.Scheme, "http") {
		uRL.Scheme = "https"
	}
	uRL.Fragment = ""
	uRL.RawFragment = ""
	uRL.User = nil
	value = uRL.String()
	if strings.HasSuffix(value, "/") {
		value = strings.TrimSuffix(value, "/")
	}
	return &value
}

// NormalizeThumbnailURL resolves relative images against an optional base, then applies
// feed URL normalization.
func NormalizeThumbnailURL(raw string, base *string) *string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return nil
	}
	if !strings.HasPrefix(strings.ToLower(value), "http") && base != nil {
		relative, err := url.Parse(value)
		parent, baseParseErr := url.Parse(*base)
		if err == nil && baseParseErr == nil {
			value = parent.ResolveReference(relative).String()
		}
	}
	if !strings.HasPrefix(strings.ToLower(value), "http") {
		return nil
	}
	return NormalizeFeedURL(value)
}

// AcceptsMediaURL admits image media hints or recognized URL forms; explicit non-image
// hints are rejected.
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
	uRL, err := url.Parse(raw)
	if err != nil {
		return false
	}
	path := strings.ToLower(uRL.Path)
	for _, extension := range []string{".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".bmp"} {
		if strings.HasSuffix(path, extension) || strings.Contains(path, extension+"?") {
			return true
		}
	}
	return false
}

// FirstImageURL returns the first real img source, falling back to the first og:image
// attribute after tokenizing the whole document.
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

// ResolveThumbnail prefers a normalized stored image, then content HTML, then summary
// HTML, using article URL before feed URL as base.
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
