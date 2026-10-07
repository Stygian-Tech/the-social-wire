package podcastcore

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// PrivateStorage uses the Swift AES-GCM combined representation: nonce, ciphertext, tag.
type PrivateStorage struct{ aead cipher.AEAD }

func NewPrivateStorage(base64Key string) (*PrivateStorage, error) {
	key, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil || len(key) != 32 {
		return nil, ErrPrivateStorageUnavailable
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, ErrPrivateStorageUnavailable
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, ErrPrivateStorageUnavailable
	}
	return &PrivateStorage{aead: aead}, nil
}
func privateContext(viewer, entity, id string) []byte {
	return []byte(fmt.Sprintf("podcast-private:v1:%d:%s:%s:%s", len(viewer), viewer, entity, id))
}
func (s *PrivateStorage) Seal(plaintext, viewer, entity, id string) (string, error) {
	if s == nil || s.aead == nil {
		return "", ErrPrivateStorageUnavailable
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", ErrPrivateStorageUnavailable
	}
	combined := s.aead.Seal(nonce, nonce, []byte(plaintext), privateContext(viewer, entity, id))
	return "v1." + base64.StdEncoding.EncodeToString(combined), nil
}
func (s *PrivateStorage) Open(payload, viewer, entity, id string) (string, error) {
	if s == nil || s.aead == nil || !strings.HasPrefix(payload, "v1.") {
		return "", ErrPrivateStorageUnavailable
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(payload, "v1."))
	if err != nil || len(data) < s.aead.NonceSize()+s.aead.Overhead() {
		return "", ErrPrivateStorageUnavailable
	}
	n := s.aead.NonceSize()
	plaintext, err := s.aead.Open(nil, data[:n], data[n:], privateContext(viewer, entity, id))
	if err != nil || !utf8.Valid(plaintext) {
		return "", ErrPrivateStorageUnavailable
	}
	return string(plaintext), nil
}
