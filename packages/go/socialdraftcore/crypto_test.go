package socialdraftcore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"io"
	"os"
	"testing"
)

func testCrypto(t *testing.T) *Service {
	t.Helper()
	g, e := newGCM(bytes.Repeat([]byte{7}, 32))
	if e != nil {
		t.Fatal(e)
	}
	return &Service{gcm: g}
}
func TestBinaryEncryptionIntegrity(t *testing.T) {
	s := testCrypto(t)
	p := bytes.Repeat([]byte{0, 255, 128, 1, 13, 10}, 30000)
	var b bytes.Buffer
	if e := s.encrypt(&b, bytes.NewReader(p), "did:plc:a", "id"); e != nil {
		t.Fatal(e)
	}
	encrypted := append([]byte(nil), b.Bytes()...)
	if bytes.Contains(encrypted, p[:100]) {
		t.Fatal("plaintext present")
	}
	var out bytes.Buffer
	if e := s.decrypt(&out, bytes.NewReader(encrypted), "did:plc:a", "id", int64(len(p))); e != nil || !bytes.Equal(out.Bytes(), p) {
		t.Fatalf("roundtrip %v", e)
	}
	cases := map[string][]byte{"truncated": encrypted[:len(encrypted)-1], "no terminal": encrypted[:len(encrypted)-32], "extra": append(append([]byte(nil), encrypted...), 0), "corrupt": append([]byte(nil), encrypted...)}
	cases["corrupt"][50] ^= 1
	for name, b := range cases {
		t.Run(name, func(t *testing.T) {
			if e := s.decrypt(io.Discard, bytes.NewReader(b), "did:plc:a", "id", int64(len(p))); e == nil {
				t.Fatal("accepted damaged ciphertext")
			}
		})
	}
	for _, pair := range [][2]string{{"did:plc:b", "id"}, {"did:plc:a", "other"}} {
		if e := s.decrypt(io.Discard, bytes.NewReader(encrypted), pair[0], pair[1], int64(len(p))); e == nil {
			t.Fatal("accepted swapped identity")
		}
	}
}
func TestTemporaryReaderCleanup(t *testing.T) {
	f, e := tempFile()
	if e != nil {
		t.Fatal(e)
	}
	name := f.Name()
	info, _ := f.Stat()
	if info.Mode().Perm() != 0600 {
		t.Fatal(info.Mode())
	}
	r := &temporaryReader{f}
	r.Close()
	if _, e = os.Stat(name); !os.IsNotExist(e) {
		t.Fatal("temporary file remains")
	}
}
func TestValidation(t *testing.T) {
	for _, s := range []string{"WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n", "\ufeffWEBVTT\r\n\r\n"} {
		if e := validateCaption(bytes.NewBufferString(s)); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range []string{"", "hello", "WEBVTTevil", "WEBVTT\n\x00", "WEBVTT\n\xff"} {
		if e := validateCaption(bytes.NewBufferString(s)); e == nil {
			t.Fatalf("accepted %q", s)
		}
	}
	if !tidPattern.MatchString("3l5hgbwxk3c2a") || tidPattern.MatchString("z234567abcdef") {
		t.Fatal("TID validation")
	}
	in := ReserveInput{AssetID: "12345678-1234-1234-1234-123456789abc", Name: "private.png", ContentType: "image/png", ByteLength: 8, SHA256: hex.EncodeToString(make([]byte, 32)), Kind: "photo"}
	if !validReserve(in) {
		t.Fatal("valid reservation rejected")
	}
	in.ContentType = "image/gif"
	if !validReserve(in) {
		t.Fatal("GIF photo rejected")
	}
	in.ContentType = "text/html"
	if validReserve(in) {
		t.Fatal("unsupported MIME accepted")
	}
	in.ContentType = "image/png"
	in.ByteLength = MaxFileBytes + 1
	if validReserve(in) {
		t.Fatal("accepted oversize")
	}
}
func TestFailClosed(t *testing.T) {
	c := Config{Endpoint: "https://s3.example", Bucket: "private", Region: "auto", AccessKeyID: "key", SecretAccessKey: "secret", StorageKey: base64.StdEncoding.EncodeToString(make([]byte, 32)), Enabled: true}
	// A nil DB and all invalid keys must fail before any remote operation.
	if _, e := New(nil, c); e != ErrUnavailable {
		t.Fatal(e)
	}
	for _, key := range []string{"", "not-base64", base64.StdEncoding.EncodeToString(make([]byte, 31)), base64.StdEncoding.EncodeToString(make([]byte, 33))} {
		bad := c
		bad.StorageKey = key
		if _, e := New(&sql.DB{}, bad); e != ErrUnavailable {
			t.Fatal(e)
		}
	}
	if _, e := New(&sql.DB{}, c); e != nil {
		t.Fatal(e)
	}
	var s *Service
	if _, e := s.Reserve(context.Background(), "did:plc:a", ReserveInput{}); e != ErrUnavailable {
		t.Fatal(e)
	}
}
func TestContentSniff(t *testing.T) {
	f, e := tempFile()
	if e != nil {
		t.Fatal(e)
	}
	defer discard(f)
	f.Write([]byte("not a PNG"))
	if e = validateContent(f, Asset{ContentType: "image/png"}); e != ErrInvalid {
		t.Fatal(e)
	}
}
func sum(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
