package podcastcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/rivo/uniseg"
)

var (
	ErrRevisionConflict          = errors.New("podcast revision conflict")
	ErrInvalidState              = errors.New("invalid podcast state")
	ErrNotFound                  = errors.New("podcast not found")
	ErrInvalidRequest            = errors.New("invalid podcast request")
	ErrPrivateStorageUnavailable = errors.New("private podcast storage unavailable")
)

func decodeRequired(data []byte, target any, required ...string) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, key := range required {
		value, ok := fields[key]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return ErrInvalidRequest
		}
	}
	return json.Unmarshal(data, target)
}

func DefaultListenerState() ListenerState {
	return ListenerState{Subscriptions: []string{}, Queue: []string{}, Progress: map[string]Progress{}, PlaybackSpeed: 1, ManualLinks: []ManualLink{}}
}
func (s ListenerState) Validate() bool {
	if math.IsNaN(s.PlaybackSpeed) || math.IsInf(s.PlaybackSpeed, 0) || s.PlaybackSpeed < .75 || s.PlaybackSpeed > 2 || s.PlaybackSpeed*4 != math.Round(s.PlaybackSpeed*4) || len(s.Queue) > 1000 || len(s.Subscriptions) > 10000 || len(s.ManualLinks) > 1000 || len(s.Progress) > 10000 {
		return false
	}
	for _, p := range s.Progress {
		if math.IsNaN(p.PositionSeconds) || math.IsInf(p.PositionSeconds, 0) || p.PositionSeconds < 0 {
			return false
		}
		if _, err := time.Parse(time.RFC3339Nano, p.UpdatedAt); err != nil {
			return false
		}
	}
	return true
}
func (s *ListenerState) NormalizePlaybackSpeed() {
	if math.IsNaN(s.PlaybackSpeed) || math.IsInf(s.PlaybackSpeed, 0) {
		s.PlaybackSpeed = 1
		return
	}
	s.PlaybackSpeed = math.Round(math.Min(2, math.Max(.75, s.PlaybackSpeed))*4) / 4
}
func (r SearchRequest) Validate() error {
	count := uniseg.GraphemeClusterCount(strings.TrimSpace(r.Query))
	scope, kind, limit := "library", "all", 20
	if r.Scope != nil {
		scope = *r.Scope
	}
	if r.Kind != nil {
		kind = *r.Kind
	}
	if r.Limit != nil {
		limit = *r.Limit
	}
	if count < 2 || count > 200 || (scope != "library" && scope != "directory") || (kind != "all" && kind != "shows" && kind != "episodes") || limit < 1 || limit > 100 {
		return ErrInvalidRequest
	}
	if r.ShowID != nil && uniseg.GraphemeClusterCount(*r.ShowID) > 2048 || r.Cursor != nil && uniseg.GraphemeClusterCount(*r.Cursor) > 4096 {
		return ErrInvalidRequest
	}
	return nil
}
