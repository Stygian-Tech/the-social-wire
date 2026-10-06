package signedcursor

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

type Codec struct{ secret []byte }

func New(secret []byte) (*Codec, error) {
	if len(secret) < 32 {
		return nil, ErrSecret
	}
	return &Codec{append([]byte(nil), secret...)}, nil
}
func (c *Codec) MAC(message []byte) []byte {
	mac := hmac.New(sha256.New, c.secret)
	mac.Write(message)
	return mac.Sum(nil)
}
func (c *Codec) Encode(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data) + "." + base64.RawURLEncoding.EncodeToString(c.MAC(data)), nil
}
func (c *Codec) Decode(value string, target any) error {
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
	if base64.RawURLEncoding.EncodeToString(data) != parts[0] || base64.RawURLEncoding.EncodeToString(signature) != parts[1] || !hmac.Equal(signature, c.MAC(data)) {
		return ErrSignature
	}
	if err := json.Unmarshal(data, target); err != nil {
		return ErrMalformed
	}
	return nil
}
