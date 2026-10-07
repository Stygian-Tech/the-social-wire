package podcastcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

func (s *Store) UpdateMetadata(ctx context.Context, e Episode, viewer *string) error {
	if e.Visibility != nil && *e.Visibility == "private" {
		if viewer == nil {
			return ErrInvalidRequest
		}
		storage, err := s.requirePrivate()
		if err != nil {
			return err
		}
		var ciphertext string
		if err := s.DB.QueryRowContext(ctx, `SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=$1 AND id=$2`, viewer, e.ID).Scan(&ciphertext); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil
			}
			return err
		}
		current, err := openJSON[Episode](storage, ciphertext, *viewer, "episode", e.ID)
		if err != nil {
			return err
		}
		if current.ID != e.ID || current.ShowID != e.ShowID || current.AudioURL != e.AudioURL || !equalString(current.ChapterSourceURL, e.ChapterSourceURL) {
			return nil
		}
		current.Chapters = e.Chapters
		current.ShowArtworkURL = e.ShowArtworkURL
		raw, err := jsonValue(current)
		if err != nil {
			return err
		}
		encrypted, err := storage.Seal(raw, *viewer, "episode", e.ID)
		if err != nil {
			return err
		}
		_, err = s.DB.ExecContext(ctx, `UPDATE podcast_private_episodes SET episode_data=$1 WHERE viewer_did=$2 AND id=$3 AND episode_data=$4`, encrypted, viewer, e.ID, ciphertext)
		return err
	}
	if IsPrivateID(e.ID) {
		return ErrInvalidRequest
	}
	chapters := e.Chapters
	if chapters == nil {
		chapters = []Chapter{}
	}
	fields, err := json.Marshal(map[string]any{"chapters": chapters, "showArtworkUrl": e.ShowArtworkURL})
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `UPDATE podcast_episodes SET episode_json=episode_json || $1::jsonb WHERE id=$2 AND show_id=$3 AND episode_json->>'audioUrl'=$4 AND episode_json->>'chapterSourceUrl' IS NOT DISTINCT FROM $5::text`, string(fields), e.ID, e.ShowID, e.AudioURL, e.ChapterSourceURL)
	return err
}
