package appviewcore

import (
	"encoding/json"
	"time"
)

type UnreadCounter struct {
	PublicationID string    `json:"publicationId"`
	UnreadCount   int       `json:"unreadCount"`
	Generation    int64     `json:"generation"`
	Accuracy      string    `json:"accuracy"`
	Dirty         bool      `json:"dirty"`
	CountedAt     time.Time `json:"-"`
}

func (c UnreadCounter) MarshalJSON() ([]byte, error) {
	type plain UnreadCounter
	return json.Marshal(struct {
		plain
		CountedAt string `json:"countedAt"`
	}{plain(c), c.CountedAt.UTC().Format(time.RFC3339)})
}
