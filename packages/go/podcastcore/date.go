package podcastcore

import (
	"strings"
	"time"
)

// ParseProgressDate retains ISO8601DateFormatter's accepted timezone forms,
// including the compact offsets already stored by Swift clients.
func ParseProgressDate(raw string) (time.Time, bool) { return parsePodcastDate(raw, true) }
func parsePodcastDate(raw string, fractional bool) (time.Time, bool) {
	if !fractional && strings.Contains(raw, ".") {
		return time.Time{}, false
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02T15:04:05Z0700", "2006-01-02T15:04:05Z07"} {
		if date, err := time.Parse(layout, raw); err == nil {
			return date, true
		}
	}
	return time.Time{}, false
}
