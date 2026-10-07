package publicationcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"time"
)

// EncodeFirstPage uses Foundation's reference-date encoding for the shared
// internal cache. Public API dates deliberately use whole-second ISO8601.
func EncodeFirstPage(page appviewcore.EntryPage) ([]byte, error) {
	type fields appviewcore.Entry
	type cachedEntry struct {
		fields
		PublishedAt    float64 `json:"publishedAt"`
		FeedPositionAt float64 `json:"feedPositionAt"`
	}
	entries := make([]cachedEntry, len(page.Entries))
	for i, entry := range page.Entries {
		entries[i] = cachedEntry{fields: fields(entry), PublishedAt: referenceSeconds(entry.PublishedAt), FeedPositionAt: referenceSeconds(entry.FeedPositionAt)}
	}
	return json.Marshal(struct {
		Entries []cachedEntry `json:"entries"`
		Cursor  *string       `json:"cursor,omitempty"`
	}{entries, page.Cursor})
}
func referenceSeconds(at time.Time) float64 {
	return float64(at.Unix()-978307200) + float64(at.Nanosecond())/1e9
}
