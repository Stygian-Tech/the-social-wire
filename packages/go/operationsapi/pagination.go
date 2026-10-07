package operationsapi

import (
	"encoding/base64"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

var ErrInvalidPaginationCursor = errors.New("invalid Operations pagination cursor")

type PaginationCursor struct {
	Date time.Time
	ID   string
}

func EncodePaginationCursor(date time.Time, id string) string {
	return base64.StdEncoding.EncodeToString([]byte(date.UTC().Format("2006-01-02T15:04:05.000Z") + "|" + id))
}
func DecodePaginationCursor(raw string) (PaginationCursor, error) {
	if utf8.RuneCountInString(raw) > 1024 {
		return PaginationCursor{}, ErrInvalidPaginationCursor
	}
	data, err := base64.StdEncoding.Strict().DecodeString(raw)
	if err != nil || base64.StdEncoding.EncodeToString(data) != raw || !utf8.Valid(data) {
		return PaginationCursor{}, ErrInvalidPaginationCursor
	}
	dateText, id, found := strings.Cut(string(data), "|")
	if !found || id == "" || utf8.RuneCountInString(id) > 512 {
		return PaginationCursor{}, ErrInvalidPaginationCursor
	}
	for _, r := range id {
		if r < 0x20 || r == 0x7f {
			return PaginationCursor{}, ErrInvalidPaginationCursor
		}
	}
	date, err := time.Parse(time.RFC3339Nano, dateText)
	if err != nil || !strings.Contains(dateText, ".") {
		return PaginationCursor{}, ErrInvalidPaginationCursor
	}
	return PaginationCursor{date, id}, nil
}
