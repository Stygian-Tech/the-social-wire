package socialdraftcore

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

const chunkSize = 64 << 10

var fileMagic = []byte("TSWDA\x01")

func aad(owner, id, domain string, index uint64) []byte {
	b, _ := json.Marshal([]any{"socialdraft", 1, owner, id, domain, index})
	return b
}
func newGCM(key []byte) (cipher.AEAD, error) {
	b, e := aes.NewCipher(key)
	if e != nil {
		return nil, e
	}
	return cipher.NewGCM(b)
}
func seal(g cipher.AEAD, plain, additional []byte) ([]byte, error) {
	n := make([]byte, g.NonceSize())
	if _, e := rand.Read(n); e != nil {
		return nil, e
	}
	return g.Seal(n, n, plain, additional), nil
}
func unseal(g cipher.AEAD, b, additional []byte) ([]byte, error) {
	if len(b) < g.NonceSize() {
		return nil, ErrInvalid
	}
	return g.Open(nil, b[:g.NonceSize()], b[g.NonceSize():], additional)
}
func tempFile() (*os.File, error) { return os.CreateTemp("", "social-draft-*") }
func discard(f *os.File)          { f.Close(); os.Remove(f.Name()) }

// Each frame has an independent random nonce. The authenticated terminal frame
// prevents truncation at a chunk boundary; AAD prevents reordering or substitution.
func (s *Service) encrypt(dst io.Writer, src io.Reader, owner, id string) error {
	if _, e := dst.Write(fileMagic); e != nil {
		return e
	}
	buf := make([]byte, chunkSize)
	for i := uint64(0); ; i++ {
		n, e := io.ReadFull(src, buf)
		if e != nil && e != io.EOF && e != io.ErrUnexpectedEOF {
			return e
		}
		if n > 0 {
			if e := s.frame(dst, buf[:n], owner, id, i); e != nil {
				return e
			}
			continue
		}
		return s.frame(dst, nil, owner, id, i)
	}
}
func (s *Service) frame(w io.Writer, p []byte, owner, id string, i uint64) error {
	b, e := seal(s.gcm, p, aad(owner, id, "file", i))
	if e != nil {
		return e
	}
	if e = binary.Write(w, binary.BigEndian, uint32(len(b))); e != nil {
		return e
	}
	_, e = w.Write(b)
	return e
}
func (s *Service) decrypt(dst io.Writer, src io.Reader, owner, id string, expected int64) error {
	header := make([]byte, len(fileMagic))
	if _, e := io.ReadFull(src, header); e != nil || string(header) != string(fileMagic) {
		return ErrInvalid
	}
	var total int64
	for i := uint64(0); ; i++ {
		var n uint32
		if binary.Read(src, binary.BigEndian, &n) != nil || n < uint32(s.gcm.NonceSize()+s.gcm.Overhead()) || n > chunkSize+uint32(s.gcm.NonceSize()+s.gcm.Overhead()) {
			return ErrInvalid
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(src, b); e != nil {
			return ErrInvalid
		}
		p, e := unseal(s.gcm, b, aad(owner, id, "file", i))
		if e != nil {
			return ErrInvalid
		}
		if len(p) == 0 {
			if total != expected {
				return ErrInvalid
			}
			var extra [1]byte
			n, e := io.ReadFull(src, extra[:])
			if n != 0 || e != io.EOF {
				return ErrInvalid
			}
			return nil
		}
		total += int64(len(p))
		if total > expected {
			return ErrInvalid
		}
		if _, e = dst.Write(p); e != nil {
			return fmt.Errorf("temporary file write: %w", e)
		}
	}
}
