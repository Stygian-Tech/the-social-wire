package appviewcore

import (
	"encoding/json"
	"time"
)

type UnreadCountsResponse struct {
	Counts     map[string]int `json:"counts"`
	Generation *int64         `json:"generation,omitempty"`
	Accuracy   *string        `json:"accuracy,omitempty"`
	CountedAt  *time.Time     `json:"countedAt,omitempty"`
}

func (v UnreadCountsResponse) MarshalJSON() ([]byte, error) {
	var at *string
	if v.CountedAt != nil {
		s := v.CountedAt.UTC().Format(time.RFC3339)
		at = &s
	}
	return json.Marshal(struct {
		Counts     map[string]int `json:"counts"`
		Generation *int64         `json:"generation,omitempty"`
		Accuracy   *string        `json:"accuracy,omitempty"`
		CountedAt  *string        `json:"countedAt,omitempty"`
	}{v.Counts, v.Generation, v.Accuracy, at})
}
