package wirecore

// Produces stable secret-keyed actor pseudonyms after trim/lowercase normalization. The
// secret is copied on construction; rotating it intentionally changes actor identity and
// requires a coordinated derived-data rebuild.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
)

// ActorHasher holds a copied secret for stable HMAC actor pseudonyms.
type ActorHasher struct{ secret []byte }

// NewActorHasher requires at least 32 secret bytes and isolates the key from subsequent
// caller mutations.
func NewActorHasher(secret []byte) (*ActorHasher, error) {
	if len(secret) < 32 {
		return nil, errors.New("invalid actor secret")
	}
	return &ActorHasher{append([]byte(nil), secret...)}, nil
}

// Hash normalizes the actor identifier and returns a versioned h1: HMAC-SHA256 pseudonym.
func (hasher *ActorHasher) Hash(actorID string) (string, error) {
	id := strings.ToLower(strings.TrimSpace(actorID))
	if id == "" {
		return "", errors.New("invalid actor ID")
	}
	mac := hmac.New(sha256.New, hasher.secret)
	mac.Write([]byte(id))
	return "h1:" + hex.EncodeToString(mac.Sum(nil)), nil
}
