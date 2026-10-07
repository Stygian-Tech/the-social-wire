package topicreadcore

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestTopicCursorAcceptsSwiftDateAndRejectsWrongContext(t *testing.T) {
	secret := []byte(strings.Repeat("a", 32))
	codec, err := NewTopicCursorCodec(secret)
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(`{"feed":"finance","generationID":"generation","language":"en","preferenceFingerprint":"revision","viewerScope":"viewer","nextOrdinal":5,"expiresAt":813110401.5}`)
	mac := hmac.New(sha256.New, secret)
	mac.Write(raw)
	encoded := base64.RawURLEncoding.EncodeToString(raw) + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	cursor, err := codec.Decode(encoded, "en", "revision", "viewer", "finance", now)
	if err != nil || cursor.NextOrdinal != 5 {
		t.Fatal(cursor, err)
	}
	if _, err = codec.Decode(encoded, "en", "revision", "other", "finance", now); !errors.Is(err, ErrInvalidCursor) {
		t.Fatal(err)
	}
	if _, err = codec.Decode(encoded, "en", "revision", "viewer", "finance", time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)); !errors.Is(err, ErrCursorExpired) {
		t.Fatal(err)
	}
}
