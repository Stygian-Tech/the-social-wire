package appviewcore

import "time"

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
