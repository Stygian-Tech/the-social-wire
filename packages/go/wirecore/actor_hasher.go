package wirecore

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

type ActorHasher struct{ secret []byte }

func NewActorHasher(secret []byte) (*ActorHasher, error) {
	if len(secret) < 32 {
		return nil, errors.New("invalid actor secret")
	}
	return &ActorHasher{append([]byte(nil), secret...)}, nil
}
func (h *ActorHasher) Hash(actorID string) (string, error) {
	id := strings.ToLower(strings.TrimSpace(actorID))
	if id == "" {
		return "", errors.New("invalid actor ID")
	}
	mac := hmac.New(sha256.New, h.secret)
	mac.Write([]byte(id))
	return "h1:" + hex.EncodeToString(mac.Sum(nil)), nil
}
