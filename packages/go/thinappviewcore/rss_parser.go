package thinappviewcore

// Translates publisher RSS, Atom, and JSON Feed bytes through gofeed into shared item
// fields. Published/updated timestamps fall back to the supplied clock, are rendered in
// UTC, and are sorted by actual instant. Network fetching and durable ingestion remain
// caller responsibilities.

import (
	"bytes"
	"sort"
	"strings"
	"time"

	"github.com/mmcdole/gofeed"
)

// ParsedRSSItem retains the publisher’s article identity, text/HTML, UTC date, and
// selected thumbnail.
type ParsedRSSItem struct {
	GUID           *string `json:"guid,omitempty"`
	Title          string  `json:"title"`
	Link           *string `json:"link,omitempty"`
	Summary        *string `json:"summary,omitempty"`
	ContentHTML    *string `json:"contentHTML,omitempty"`
	PublishedAtISO string  `json:"publishedAtISO"`
	ThumbnailURL   *string `json:"thumbnailUrl,omitempty"`
}

// ParsedRSSFeed contains an optional publisher title and newest-first parsed items.
type ParsedRSSFeed struct {
	Title *string         `json:"title,omitempty"`
	Items []ParsedRSSItem `json:"items"`
}

func optionalValue(value string) *string { return &value }
func feedValue(value string) *string {
	if value == "" {
		return nil
	}
	return optionalValue(value)
}

// ParseRSS parses publisher-supplied bytes with gofeed. Fetching stays with the
// caller so its DNS, redirect, response-size, and timeout policies still apply.
func ParseRSS(data []byte, feedURL *string, now time.Time) (ParsedRSSFeed, error) {
	result := ParsedRSSFeed{Items: []ParsedRSSItem{}}
	parsed, err := gofeed.NewParser().Parse(bytes.NewReader(data))
	if parsed == nil {
		return result, err
	}
	result.Title = feedValue(parsed.Title)
	for _, source := range parsed.Items {
		item := ParsedRSSItem{
			GUID: feedValue(source.GUID), Title: strings.TrimSpace(source.Title),
			Link: feedValue(source.Link), Summary: feedValue(source.Description),
			ContentHTML: feedValue(source.Content),
		}
		if item.Title == "" {
			item.Title = "Untitled"
		}
		published := source.PublishedParsed
		if published == nil {
			published = source.UpdatedParsed
		}
		if published == nil {
			published = &now
		}
		item.PublishedAtISO = published.UTC().Format(time.RFC3339Nano)
		image := ""
		// Keep explicit media thumbnails ahead of the translator's image fallback.
		for _, thumbnail := range source.Extensions["media"]["thumbnail"] {
			if image = thumbnail.Attrs["url"]; image != "" {
				break
			}
		}
		if image == "" && source.Image != nil {
			image = source.Image.URL
		}
		if image == "" {
			for _, enclosure := range source.Enclosures {
				if AcceptsMediaURL(enclosure.URL, feedValue(enclosure.Type), nil) {
					image = enclosure.URL
					break
				}
			}
		}
		item.ThumbnailURL = ResolveThumbnail(image, source.Content, source.Description, item.Link, feedURL)
		result.Items = append(result.Items, item)
	}
	sort.SliceStable(result.Items, func(itemIndex, comparisonIndex int) bool {
		leftPublishedAt, _ := time.Parse(time.RFC3339Nano, result.Items[itemIndex].PublishedAtISO)
		rightPublishedAt, _ := time.Parse(time.RFC3339Nano, result.Items[comparisonIndex].PublishedAtISO)
		return leftPublishedAt.After(rightPublishedAt)
	})
	return result, err
}
