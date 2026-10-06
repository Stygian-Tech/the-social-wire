package sportscore

// Models membership as a half-open time interval. JSON decoding accepts RFC3339 strings
// and legacy Swift Date numbers measured in seconds since 2001-01-01, preserving
// fractional seconds.

import (
	"encoding/json"
	"errors"
	"math"
	"time"
)

// Membership associates an entity with a half-open validity interval and optional season.
type Membership struct {
	EntityID   string     `json:"entityID"`
	ValidFrom  time.Time  `json:"validFrom"`
	ValidUntil *time.Time `json:"validUntil,omitempty"`
	Season     *string    `json:"season,omitempty"`
}

// Includes accepts the inclusive start and excludes the optional end instant.
func (membership Membership) Includes(at time.Time) bool {
	return !at.Before(membership.ValidFrom) && (membership.ValidUntil == nil || at.Before(*membership.ValidUntil))
}

// UnmarshalJSON decodes the shared wire representation while enforcing this type’s
// compatibility rules.
func (membership *Membership) UnmarshalJSON(data []byte) error {
	var raw struct {
		EntityID   string
		ValidFrom  json.RawMessage
		ValidUntil json.RawMessage
		Season     *string
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	parse := func(raw json.RawMessage) (time.Time, error) {
		if len(raw) == 0 || string(raw) == "null" {
			return time.Time{}, errors.New("missing membership date")
		}
		var number float64
		if err := json.Unmarshal(raw, &number); err == nil && !math.IsNaN(number) && !math.IsInf(number, 0) {
			whole, fraction := math.Modf(number)
			return time.Unix(978307200+int64(whole), int64(fraction*1e9)).UTC(), nil
		}
		var text string
		if err := json.Unmarshal(raw, &text); err != nil {
			return time.Time{}, err
		}
		return time.Parse(time.RFC3339Nano, text)
	}
	start, err := parse(raw.ValidFrom)
	if err != nil {
		return err
	}
	*membership = Membership{EntityID: raw.EntityID, ValidFrom: start, Season: raw.Season}
	if len(raw.ValidUntil) > 0 && string(raw.ValidUntil) != "null" {
		end, err := parse(raw.ValidUntil)
		if err != nil {
			return err
		}
		membership.ValidUntil = &end
	}
	return nil
}
