package wirecore

// Adds field/version validation around the shared signed envelope. Wire cursors bind
// generation/language/ordinal; Circle additionally binds a secret-derived viewer identity,
// snapshot, and second-precision expiry checked against the caller clock.

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

// Cursor identifies a Wire generation/language and the next ranked ordinal.
type Cursor struct {
	GenerationID string
	Language     string
	NextOrdinal  int
}

// CursorCodec signs and validates Wire generation cursors using the shared envelope codec.
type CursorCodec struct{ codec *signedcursor.Codec }

// NewCursorCodec requires a copied secret of at least 32 bytes.
func NewCursorCodec(secret []byte) (*CursorCodec, error) {
	codec, err := signedcursor.New(secret)
	if err != nil {
		return nil, err
	}
	return &CursorCodec{codec}, nil
}

type cursorPayload struct {
	Version     *int    `json:"version"`
	Generation  *string `json:"generation"`
	Language    *string `json:"language"`
	NextOrdinal *int    `json:"nextOrdinal"`
}

func validCursor(cursor Cursor) bool {
	return cursor.NextOrdinal >= 0 && len(cursor.GenerationID) > 0 && len(cursor.GenerationID) <= 128 && len(cursor.Language) > 0 && len(cursor.Language) <= 35
}

// Encode validates fields and signs their JSON representation for a subsequent
// authenticated decode.
func (codec *CursorCodec) Encode(cursor Cursor) (string, error) {
	if !validCursor(cursor) {
		return "", ErrCursorPayload
	}
	version := 1
	return codec.codec.Encode(cursorPayload{&version, &cursor.GenerationID, &cursor.Language, &cursor.NextOrdinal})
}

// Decode verifies the signed envelope before accepting domain fields; failures return no
// usable cursor.
func (codec *CursorCodec) Decode(encoded string) (Cursor, error) {
	var payload cursorPayload
	if err := codec.codec.Decode(encoded, &payload); err != nil {
		return Cursor{}, err
	}
	if payload.Version == nil || payload.Generation == nil || payload.Language == nil || payload.NextOrdinal == nil {
		return Cursor{}, signedcursor.ErrMalformed
	}
	if *payload.Version != 1 {
		return Cursor{}, ErrCursorVersion
	}
	cursor := Cursor{*payload.Generation, *payload.Language, *payload.NextOrdinal}
	if !validCursor(cursor) {
		return Cursor{}, ErrCursorPayload
	}
	return cursor, nil
}

// CircleCursor adds snapshot and expiry to the Wire position used for viewer-specific
// pagination.
type CircleCursor struct {
	SnapshotID, GenerationID, Language string
	NextOrdinal                        int
	ExpiresAt                          time.Time
}

// CircleCursorCodec signs viewer-bound Circle snapshots and validates their expiry.
type CircleCursorCodec struct{ codec *signedcursor.Codec }

// NewCircleCursorCodec requires a copied secret of at least 32 bytes for Circle cursor and
// viewer binding MACs.
func NewCircleCursorCodec(secret []byte) (*CircleCursorCodec, error) {
	codec, err := signedcursor.New(secret)
	if err != nil {
		return nil, err
	}
	return &CircleCursorCodec{codec}, nil
}

// ViewerBinding returns a domain-separated secret MAC of the normalized viewer instead of
// placing its raw identifier in the cursor.
func (codec *CircleCursorCodec) ViewerBinding(viewer string) (string, error) {
	viewer = strings.ToLower(strings.TrimSpace(viewer))
	if len(viewer) == 0 || len(viewer) > 2048 {
		return "", ErrCursorPayload
	}
	return "cv1:" + base64.RawURLEncoding.EncodeToString(codec.codec.MAC([]byte("circle-viewer-v1\n"+viewer))), nil
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

func validCircleCursor(cursor CircleCursor) bool {
	return validCursor(Cursor{cursor.GenerationID, cursor.Language, cursor.NextOrdinal}) && len(cursor.SnapshotID) > 0 && len(cursor.SnapshotID) <= 128 && cursor.ExpiresAt.After(time.Unix(0, 0))
}

// Encode validates fields and signs their JSON representation for a subsequent
// authenticated decode.
func (codec *CircleCursorCodec) Encode(cursor CircleCursor, viewer string) (string, error) {
	if !validCircleCursor(cursor) {
		return "", ErrCursorPayload
	}
	binding, err := codec.ViewerBinding(viewer)
	if err != nil {
		return "", err
	}
	version := 1
	expiry := cursor.ExpiresAt.Unix()
	return codec.codec.Encode(circleCursorPayload{&version, &binding, &cursor.SnapshotID, &cursor.GenerationID, &cursor.Language, &cursor.NextOrdinal, &expiry})
}

// Decode verifies the signed envelope before accepting domain fields; failures return no
// usable cursor.
func (codec *CircleCursorCodec) Decode(encoded, viewer string, now time.Time) (CircleCursor, error) {
	var payload circleCursorPayload
	if err := codec.codec.Decode(encoded, &payload); err != nil {
		return CircleCursor{}, err
	}
	if payload.Version == nil || payload.Viewer == nil || payload.Snapshot == nil || payload.Generation == nil || payload.Language == nil || payload.NextOrdinal == nil || payload.ExpiresAt == nil {
		return CircleCursor{}, signedcursor.ErrMalformed
	}
	if *payload.Version != 1 {
		return CircleCursor{}, ErrCursorVersion
	}
	binding, err := codec.ViewerBinding(viewer)
	if err != nil {
		return CircleCursor{}, err
	}
	if *payload.Viewer != binding {
		return CircleCursor{}, ErrViewerMismatch
	}
	cursor := CircleCursor{*payload.Snapshot, *payload.Generation, *payload.Language, *payload.NextOrdinal, time.Unix(*payload.ExpiresAt, 0)}
	if !validCircleCursor(cursor) {
		return CircleCursor{}, ErrCursorPayload
	}
	if !cursor.ExpiresAt.After(now) {
		return CircleCursor{}, ErrCursorExpired
	}
	return cursor, nil
}
