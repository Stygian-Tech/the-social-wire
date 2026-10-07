package sportscore

import (
	"encoding/json"
	"time"
)

// An unavailable table has no observation time, matching the optional Swift Date.
func (s StandingSnapshot) MarshalJSON() ([]byte, error) {
	type plain StandingSnapshot
	var at *time.Time
	if !s.UpdatedAt.IsZero() {
		value := s.UpdatedAt
		at = &value
	}
	return json.Marshal(struct {
		plain
		UpdatedAt *time.Time `json:"updatedAt,omitempty"`
	}{plain(s), at})
}
