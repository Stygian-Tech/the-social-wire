package sportscore

import (
	"encoding/json"
	"time"
)

func (e Entity) MarshalJSON() ([]byte, error) {
	type plain Entity
	var memberships *[]Membership
	var groups *[]string
	if e.Memberships != nil {
		memberships = &e.Memberships
	}
	if e.GroupPath != nil {
		groups = &e.GroupPath
	}
	return json.Marshal(struct {
		plain
		Memberships *[]Membership `json:"memberships,omitempty"`
		GroupPath   *[]string     `json:"groupPath,omitempty"`
	}{plain(e), memberships, groups})
}
func (m Membership) MarshalJSON() ([]byte, error) {
	date := func(value time.Time) float64 {
		return float64(value.Unix()-978307200) + float64(value.Nanosecond())/1e9
	}
	value := map[string]any{"entityID": m.EntityID, "validFrom": date(m.ValidFrom)}
	if m.ValidUntil != nil {
		value["validUntil"] = date(*m.ValidUntil)
	}
	if m.Season != nil {
		value["season"] = *m.Season
	}
	return json.Marshal(value)
}
