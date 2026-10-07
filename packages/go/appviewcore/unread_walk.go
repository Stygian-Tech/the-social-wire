package appviewcore

import (
	"context"
	"errors"
	"time"
)

func (s ContentReader) WalkUnread(ctx context.Context, viewer string, scopes []PublicationScope, limit int, now time.Time, onPage func([]UnreadMutationEntry) error) error {
	cursor := ""
	seenCursors, seenIDs := map[string]bool{}, map[string]bool{}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		page, err := s.UnreadSnapshot(ctx, viewer, scopes, cursor, limit, now)
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		entries := []UnreadMutationEntry{}
		for _, entry := range page.Entries {
			if !seenIDs[entry.EntryID] {
				seenIDs[entry.EntryID] = true
				entries = append(entries, entry)
			}
		}
		if page.Cursor != nil {
			if seenCursors[*page.Cursor] {
				return errors.New("unread snapshot pagination did not advance")
			}
			seenCursors[*page.Cursor] = true
		}
		if err := onPage(entries); err != nil {
			return err
		}
		if page.Cursor == nil {
			return nil
		}
		cursor = *page.Cursor
	}
}
