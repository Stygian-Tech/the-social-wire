package publicationcore

import "time"

type CounterSnapshot struct {
	Counts                map[string]int `json:"counts"`
	Generation            int64          `json:"generation"`
	Accuracy              string         `json:"accuracy"`
	CountedAt             time.Time      `json:"countedAt"`
	Dirty                 bool           `json:"dirty"`
	MissingPublicationIDs []string       `json:"missingPublicationIds"`
}
