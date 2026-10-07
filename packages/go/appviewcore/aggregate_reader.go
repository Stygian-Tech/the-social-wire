package appviewcore

import (
	"context"
	"errors"
	"time"
)

func (s ContentReader) EntriesUpTo(ctx context.Context, q EntryQuery, maxEntries int, now time.Time) (EntryPage, error) {
	if maxEntries < 1 || maxEntries > 500 {
		return EntryPage{}, errors.New("invalid maximum entries")
	}
	result := EntryPage{Entries: []Entry{}}
	seen, seenCursors := map[string]bool{}, map[string]bool{}
	q.Cursor = ""
	for {
		page, err := s.Entries(ctx, q, now)
		if err != nil {
			return EntryPage{}, err
		}
		for _, entry := range page.Entries {
			if !seen[entry.EntryID] {
				seen[entry.EntryID] = true
				result.Entries = append(result.Entries, entry)
			}
		}
		if len(result.Entries) >= maxEntries {
			overflow := len(result.Entries) > maxEntries
			result.Entries = result.Entries[:maxEntries]
			if overflow || page.Cursor != nil {
				last := result.Entries[maxEntries-1]
				cursor := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
				result.Cursor = &cursor
			}
			return result, nil
		}
		if len(page.Entries) == 0 || page.Cursor == nil {
			return result, nil
		}
		if seenCursors[*page.Cursor] {
			return EntryPage{}, errors.New("entry pagination did not advance")
		}
		seenCursors[*page.Cursor] = true
		q.Cursor = *page.Cursor
	}
}
