package podcastcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
)

func (s *Store) State(ctx context.Context, viewer string) (StateSnapshot, error) {
	var revision int64
	var raw string
	err := s.DB.QueryRowContext(ctx, `SELECT revision,state_json::text FROM podcast_viewer_state WHERE viewer_did=$1`, viewer).Scan(&revision, &raw)
	if errors.Is(err, sql.ErrNoRows) {
		return StateSnapshot{State: DefaultListenerState()}, nil
	}
	if err != nil {
		return StateSnapshot{}, err
	}
	var state ListenerState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return StateSnapshot{}, err
	}
	state.NormalizePlaybackSpeed()
	return StateSnapshot{Revision: revision, State: state}, nil
}
func (s *Store) SaveState(ctx context.Context, viewer string, expected int64, state ListenerState) (StateSnapshot, error) {
	if expected < 0 || !state.Validate() {
		return StateSnapshot{}, ErrInvalidState
	}
	privateIDs := map[string]bool{}
	for _, id := range state.Queue {
		if IsPrivateID(id) {
			privateIDs[id] = true
		}
	}
	for id := range state.Progress {
		if IsPrivateID(id) {
			privateIDs[id] = true
		}
	}
	ids := make([]string, 0, len(privateIDs))
	for id := range privateIDs {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	owns, err := s.OwnsPrivateEpisodes(ctx, viewer, ids)
	if err != nil {
		return StateSnapshot{}, err
	}
	if !owns {
		return StateSnapshot{}, ErrInvalidState
	}
	data, err := jsonValue(state)
	if err != nil {
		return StateSnapshot{}, err
	}
	var revision int64
	if expected == 0 {
		err = s.DB.QueryRowContext(ctx, `INSERT INTO podcast_viewer_state(viewer_did,revision,state_json) VALUES($1,1,$2::jsonb) ON CONFLICT(viewer_did) DO UPDATE SET revision=podcast_viewer_state.revision+1,state_json=EXCLUDED.state_json,updated_at=now() WHERE podcast_viewer_state.revision=$3 RETURNING revision`, viewer, data, expected).Scan(&revision)
	} else {
		err = s.DB.QueryRowContext(ctx, `UPDATE podcast_viewer_state SET revision=revision+1,state_json=$1::jsonb,updated_at=now() WHERE viewer_did=$2 AND revision=$3 RETURNING revision`, data, viewer, expected).Scan(&revision)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return StateSnapshot{}, ErrRevisionConflict
	}
	if err != nil {
		return StateSnapshot{}, err
	}
	return StateSnapshot{Revision: revision, State: state}, nil
}
