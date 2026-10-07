package readagecore

import (
	"errors"
	"strings"
	"time"
	_ "time/tzdata"
)

var ErrInvalidCalendar = errors.New("invalid read-age calendar selection")

func Location(identifier string) (*time.Location, error) {
	if identifier != "UTC" && identifier != "GMT" && (!strings.Contains(identifier, "/") || strings.HasPrefix(identifier, "/") || strings.Contains(identifier, "..") || strings.Contains(identifier, "\\")) {
		return nil, ErrInvalidCalendar
	}
	location, err := time.LoadLocation(identifier)
	if err != nil {
		return nil, ErrInvalidCalendar
	}
	return location, nil
}
func Cutoff(raw string, now time.Time) (time.Time, error) {
	at, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil || at.After(now) {
		return time.Time{}, ErrInvalidCalendar
	}
	return at, nil
}
func Timestamp(at time.Time) string { return at.UTC().Format("2006-01-02T15:04:05.000Z") }
