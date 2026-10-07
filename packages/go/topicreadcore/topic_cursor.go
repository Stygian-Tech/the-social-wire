package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/internal/signedcursor"
	"math"
	"time"
)

type TopicCursor struct {
	Feed                  string  `json:"feed"`
	GenerationID          string  `json:"generationID"`
	Language              string  `json:"language"`
	PreferenceFingerprint string  `json:"preferenceFingerprint"`
	ViewerScope           string  `json:"viewerScope"`
	NextOrdinal           int     `json:"nextOrdinal"`
	ExpiresAt             float64 `json:"expiresAt"`
}
type TopicCursorCodec struct{ codec *signedcursor.Codec }

func NewTopicCursorCodec(secret []byte) (*TopicCursorCodec, error) {
	codec, err := signedcursor.New(secret)
	if err != nil {
		return nil, err
	}
	return &TopicCursorCodec{codec}, nil
}
func topicExpiry(at time.Time) float64 {
	return float64(at.Unix()-978307200) + float64(at.Nanosecond())/1e9
}
func (c *TopicCursorCodec) Encode(cursor TopicCursor) (string, error) {
	if cursor.Feed == "" || len(cursor.Feed) > 256 || cursor.GenerationID == "" || cursor.Language == "" || cursor.PreferenceFingerprint == "" || cursor.ViewerScope == "" || cursor.NextOrdinal < 0 || math.IsNaN(cursor.ExpiresAt) || math.IsInf(cursor.ExpiresAt, 0) {
		return "", ErrInvalidCursor
	}
	return c.codec.Encode(cursor)
}
func (c *TopicCursorCodec) Decode(raw, language, revision, viewer, feed string, now time.Time) (TopicCursor, error) {
	var value TopicCursor
	if err := c.codec.Decode(raw, &value); err != nil {
		return value, ErrInvalidCursor
	}
	if value.Feed != feed || value.GenerationID == "" || value.NextOrdinal < 0 || value.Language != language || value.PreferenceFingerprint != revision || value.ViewerScope != viewer {
		return value, ErrInvalidCursor
	}
	if value.ExpiresAt <= topicExpiry(now) {
		return value, ErrCursorExpired
	}
	return value, nil
}

func (c *TopicCursor) UnmarshalJSON(data []byte) error {
	type value TopicCursor
	var v value
	if err := decodeRequired(data, &v, "feed", "generationID", "language", "preferenceFingerprint", "viewerScope", "nextOrdinal", "expiresAt"); err != nil {
		return err
	}
	*c = TopicCursor(v)
	return nil
}
