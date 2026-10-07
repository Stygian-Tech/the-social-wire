package appviewcore

import (
	"errors"
	"strings"
	"time"
)

// EntryCursor preserves the deployed Swift cursor's timestamp|URI wire format.
type EntryCursor struct {
	CreatedAt time.Time
	URI       string
}

func (c EntryCursor) Encode() string {
	// PostgreSQL ordering retains fractional seconds. Dropping them here would
	// skip the rest of a timestamp group on the next page. The wire shape and
	// acceptance of existing second-precision cursors remain unchanged.
	return c.CreatedAt.UTC().Format(time.RFC3339Nano) + "|" + c.URI
}

func DecodeEntryCursor(raw string) (EntryCursor, error) {
	date, uri, ok := strings.Cut(raw, "|")
	if !ok || uri == "" {
		return EntryCursor{}, errors.New("invalid entry cursor")
	}
	at, err := time.Parse(time.RFC3339Nano, date)
	if err != nil {
		return EntryCursor{}, errors.New("invalid entry cursor")
	}
	return EntryCursor{CreatedAt: at, URI: uri}, nil
}
