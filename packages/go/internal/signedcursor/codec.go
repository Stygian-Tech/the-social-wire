package signedcursor

// Provides the shared HMAC-SHA256 cursor envelope: unpadded base64url JSON plus an
// authenticated signature. Secrets are copied, signatures compared in constant time, and
// noncanonical encodings rejected. Public cursor wrappers enforce domain-specific fields.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
)

var (
	ErrMalformed = errors.New("malformed cursor")
	ErrSignature = errors.New("invalid cursor signature")
	ErrSecret    = errors.New("invalid cursor secret")
)

// Codec holds a copied key for a canonical base64url JSON/HMAC envelope.
type Codec struct{ secret []byte }

// New requires at least 32 key bytes and copies them into codec-owned memory.
func New(secret []byte) (*Codec, error) {
	if len(secret) < 32 {
		return nil, ErrSecret
	}
	return &Codec{append([]byte(nil), secret...)}, nil
}

// MAC computes HMAC-SHA256 over exact bytes for envelope or domain-separated binding use.
func (codec *Codec) MAC(message []byte) []byte {
	mac := hmac.New(sha256.New, codec.secret)
	mac.Write(message)
	return mac.Sum(nil)
}

// Encode encodes JSON plus its MAC as two unpadded base64url components.
func (codec *Codec) Encode(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(codec.MAC(data)), nil
}

// Decode bounds input to 4,096 characters, requires canonical encoding, verifies HMAC,
// then decodes the payload.
func (codec *Codec) Decode(value string, target any) error {
	if len(value) == 0 || len(value) > 4096 {
		return ErrMalformed
	}
	parts := strings.Split(value, ".")
	if len(parts) != 2 {
		return ErrMalformed
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return ErrMalformed
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ErrMalformed
	}
	if base64.RawURLEncoding.EncodeToString(data) != parts[0] || base64.RawURLEncoding.EncodeToString(signature) != parts[1] || !hmac.Equal(signature, codec.MAC(data)) {
		return ErrSignature
	}
	if err := json.Unmarshal(data, target); err != nil {
		return ErrMalformed
	}
	return nil
}
