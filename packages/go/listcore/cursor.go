package listcore

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
)

var ErrCursor = errors.New("list cursor does not match this viewer, list, or filter")

type cursorPayload struct {
	Fingerprint  *string `json:"fingerprint"`
	Continuation *string `json:"continuation"`
}

func Fingerprint(viewer string, list List, filter string) string {
	material := append([]string{viewer, list.URI, filter}, list.Publications...)
	material = append(material, "authors")
	material = append(material, list.Users...)
	hash := sha256.Sum256([]byte(strings.Join(material, "\n")))
	return hex.EncodeToString(hash[:])
}
func DecodeCursor(raw *string, fingerprint string) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	if len(*raw) > 8192 {
		return nil, ErrCursor
	}
	data, err := base64.StdEncoding.DecodeString(*raw)
	if err != nil {
		return nil, ErrCursor
	}
	var payload cursorPayload
	if json.Unmarshal(data, &payload) != nil || payload.Fingerprint == nil || *payload.Fingerprint != fingerprint || payload.Continuation == nil {
		return nil, ErrCursor
	}
	return payload.Continuation, nil
}
func EncodeCursor(continuation *string, fingerprint string) *string {
	if continuation == nil {
		return nil
	}
	data, _ := json.Marshal(cursorPayload{&fingerprint, continuation})
	encoded := base64.StdEncoding.EncodeToString(data)
	return &encoded
}
