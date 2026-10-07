package appviewcore

import (
	"encoding/json"
	"time"
)

type ReadBoundary struct {
	PublicationID string    `json:"publicationId"`
	CreatedAt     time.Time `json:"-"`
	EntryID       *string   `json:"entryId,omitempty"`
}

func (b ReadBoundary) MarshalJSON() ([]byte, error) {
	type plain ReadBoundary
	return json.Marshal(struct {
		plain
		CreatedAt string `json:"createdAt"`
	}{plain(b), b.CreatedAt.UTC().Format(time.RFC3339)})
}
func (b ReadBoundary) after(other ReadBoundary) bool {
	if !b.CreatedAt.Equal(other.CreatedAt) {
		return b.CreatedAt.After(other.CreatedAt)
	}
	if b.EntryID == nil {
		return other.EntryID != nil
	}
	return other.EntryID != nil && *b.EntryID > *other.EntryID
}
func (b ReadBoundary) contains(at time.Time, uri string) bool {
	return at.Before(b.CreatedAt) || at.Equal(b.CreatedAt) && (b.EntryID == nil || uri <= *b.EntryID)
}
