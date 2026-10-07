package appviewcore

import (
	"encoding/json"
	"time"
)

type Entry struct {
	EntryID              string    `json:"entryId"`
	Title                string    `json:"title"`
	Summary              *string   `json:"summary,omitempty"`
	PublishedAt          time.Time `json:"publishedAt"`
	ThumbnailURL         *string   `json:"thumbnailUrl,omitempty"`
	ThumbnailFallbackURL *string   `json:"thumbnailFallbackUrl,omitempty"`
	OriginalURL          *string   `json:"originalUrl,omitempty"`
	PublicationID        *string   `json:"publicationId,omitempty"`
	FeedPositionAt       time.Time `json:"feedPositionAt"`
	IsRead               bool      `json:"isRead"`
}

// Swift's deployed API encoder emits whole-second ISO8601 dates. Keep that
// presentation contract without truncating the database position in memory.
func (e Entry) MarshalJSON() ([]byte, error) {
	type entryFields Entry
	return json.Marshal(struct {
		entryFields
		PublishedAt    string `json:"publishedAt"`
		FeedPositionAt string `json:"feedPositionAt"`
	}{entryFields: entryFields(e), PublishedAt: e.PublishedAt.UTC().Format(time.RFC3339), FeedPositionAt: e.FeedPositionAt.UTC().Format(time.RFC3339)})
}
