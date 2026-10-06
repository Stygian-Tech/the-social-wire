package wirecore

import (
	"encoding/base64"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/internal/signedcursor"
	"strings"
	"time"
)

var (
	ErrCursorPayload  = errors.New("invalid cursor payload")
	ErrCursorVersion  = errors.New("unsupported cursor version")
	ErrViewerMismatch = errors.New("cursor viewer mismatch")
	ErrCursorExpired  = errors.New("cursor expired")
)

type Cursor struct {
	GenerationID string
	Language     string
	NextOrdinal  int
}
type CursorCodec struct{ codec *signedcursor.Codec }

func NewCursorCodec(secret []byte) (*CursorCodec, error) {
	c, e := signedcursor.New(secret)
	if e != nil {
		return nil, e
	}
	return &CursorCodec{c}, nil
}

type cursorPayload struct {
	Version     *int    `json:"version"`
	Generation  *string `json:"generation"`
	Language    *string `json:"language"`
	NextOrdinal *int    `json:"nextOrdinal"`
}

func validCursor(c Cursor) bool {
	return c.NextOrdinal >= 0 && len(c.GenerationID) > 0 && len(c.GenerationID) <= 128 && len(c.Language) > 0 && len(c.Language) <= 35
}
func (c *CursorCodec) Encode(v Cursor) (string, error) {
	if !validCursor(v) {
		return "", ErrCursorPayload
	}
	version := 1
	return c.codec.Encode(cursorPayload{&version, &v.GenerationID, &v.Language, &v.NextOrdinal})
}
func (c *CursorCodec) Decode(encoded string) (Cursor, error) {
	var p cursorPayload
	if err := c.codec.Decode(encoded, &p); err != nil {
		return Cursor{}, err
	}
	if p.Version == nil || p.Generation == nil || p.Language == nil || p.NextOrdinal == nil {
		return Cursor{}, signedcursor.ErrMalformed
	}
	if *p.Version != 1 {
		return Cursor{}, ErrCursorVersion
	}
	v := Cursor{*p.Generation, *p.Language, *p.NextOrdinal}
	if !validCursor(v) {
		return Cursor{}, ErrCursorPayload
	}
	return v, nil
}

type CircleCursor struct {
	SnapshotID, GenerationID, Language string
	NextOrdinal                        int
	ExpiresAt                          time.Time
}
type CircleCursorCodec struct{ codec *signedcursor.Codec }

func NewCircleCursorCodec(secret []byte) (*CircleCursorCodec, error) {
	c, e := signedcursor.New(secret)
	if e != nil {
		return nil, e
	}
	return &CircleCursorCodec{c}, nil
}
func (c *CircleCursorCodec) ViewerBinding(viewer string) (string, error) {
	viewer = strings.ToLower(strings.TrimSpace(viewer))
	if len(viewer) == 0 || len(viewer) > 2048 {
		return "", ErrCursorPayload
	}
	return "cv1:" + base64.RawURLEncoding.EncodeToString(c.codec.MAC([]byte("circle-viewer-v1\n"+viewer))), nil
}

type circleCursorPayload struct {
	Version     *int    `json:"version"`
	Viewer      *string `json:"viewer"`
	Snapshot    *string `json:"snapshot"`
	Generation  *string `json:"generation"`
	Language    *string `json:"language"`
	NextOrdinal *int    `json:"nextOrdinal"`
	ExpiresAt   *int64  `json:"expiresAt"`
}

func validCircleCursor(v CircleCursor) bool {
	return validCursor(Cursor{v.GenerationID, v.Language, v.NextOrdinal}) && len(v.SnapshotID) > 0 && len(v.SnapshotID) <= 128 && v.ExpiresAt.After(time.Unix(0, 0))
}
func (c *CircleCursorCodec) Encode(v CircleCursor, viewer string) (string, error) {
	if !validCircleCursor(v) {
		return "", ErrCursorPayload
	}
	binding, err := c.ViewerBinding(viewer)
	if err != nil {
		return "", err
	}
	version := 1
	expiry := v.ExpiresAt.Unix()
	return c.codec.Encode(circleCursorPayload{&version, &binding, &v.SnapshotID, &v.GenerationID, &v.Language, &v.NextOrdinal, &expiry})
}
func (c *CircleCursorCodec) Decode(encoded, viewer string, now time.Time) (CircleCursor, error) {
	var p circleCursorPayload
	if err := c.codec.Decode(encoded, &p); err != nil {
		return CircleCursor{}, err
	}
	if p.Version == nil || p.Viewer == nil || p.Snapshot == nil || p.Generation == nil || p.Language == nil || p.NextOrdinal == nil || p.ExpiresAt == nil {
		return CircleCursor{}, signedcursor.ErrMalformed
	}
	if *p.Version != 1 {
		return CircleCursor{}, ErrCursorVersion
	}
	binding, err := c.ViewerBinding(viewer)
	if err != nil {
		return CircleCursor{}, err
	}
	if *p.Viewer != binding {
		return CircleCursor{}, ErrViewerMismatch
	}
	v := CircleCursor{*p.Snapshot, *p.Generation, *p.Language, *p.NextOrdinal, time.Unix(*p.ExpiresAt, 0)}
	if !validCircleCursor(v) {
		return CircleCursor{}, ErrCursorPayload
	}
	if !v.ExpiresAt.After(now) {
		return CircleCursor{}, ErrCursorExpired
	}
	return v, nil
}
