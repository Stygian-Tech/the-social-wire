package wirecore

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	CorpusServiceHeader    = "X-Wire-Corpus-Service"
	CorpusTimestampHeader  = "X-Wire-Corpus-Timestamp"
	CorpusNonceHeader      = "X-Wire-Corpus-Nonce"
	CorpusSignatureHeader  = "X-Wire-Corpus-Signature"
	CorpusBodyDigestHeader = "X-Wire-Corpus-Body-SHA256"
)

var (
	ErrCorpusTrust     = errors.New("invalid corpus service authentication")
	serviceIDPattern   = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,64}$`)
	corpusNoncePattern = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)
	digestPattern      = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

type CorpusServiceHeaders struct {
	ServiceID  string  `json:"serviceID"`
	Timestamp  string  `json:"timestamp"`
	Nonce      string  `json:"nonce"`
	Signature  string  `json:"signature"`
	BodyDigest *string `json:"bodyDigest,omitempty"`
}

func CorpusBodyDigest(body []byte) string { h := sha256.Sum256(body); return hex.EncodeToString(h[:]) }
func validateCorpusRequest(secret []byte, service, target, nonce string, digest *string) error {
	if len(secret) < 32 || !serviceIDPattern.MatchString(service) || !strings.HasPrefix(target, "/") || len(target) > 2048 || strings.ContainsAny(target, "#\r\n") || !corpusNoncePattern.MatchString(nonce) || digest != nil && !digestPattern.MatchString(*digest) {
		return ErrCorpusTrust
	}
	return nil
}
func corpusMessage(h CorpusServiceHeaders, method, target string) []byte {
	version := "wire-corpus-v1"
	if h.BodyDigest != nil {
		version = "wire-corpus-v2"
	}
	message := strings.Join([]string{version, h.ServiceID, h.Timestamp, h.Nonce, strings.ToUpper(method), target}, "\n")
	if h.BodyDigest != nil {
		message += "\n" + *h.BodyDigest
	}
	return []byte(message)
}
func SignCorpusRequest(secret []byte, service, method, target string, digest *string, now time.Time, nonce string) (CorpusServiceHeaders, error) {
	if nonce == "" {
		var b [16]byte
		if _, err := rand.Read(b[:]); err != nil {
			return CorpusServiceHeaders{}, err
		}
		b[6] = b[6]&15 | 64
		b[8] = b[8]&63 | 128
		nonce = fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
	}
	if err := validateCorpusRequest(secret, service, target, nonce, digest); err != nil {
		return CorpusServiceHeaders{}, err
	}
	h := CorpusServiceHeaders{ServiceID: service, Timestamp: strconv.FormatInt(now.Unix(), 10), Nonce: nonce, BodyDigest: digest}
	mac := hmac.New(sha256.New, secret)
	mac.Write(corpusMessage(h, method, target))
	h.Signature = base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return h, nil
}
func VerifyCorpusRequest(secret []byte, expectedService, method, target string, h CorpusServiceHeaders, now time.Time) error {
	if err := validateCorpusRequest(secret, expectedService, target, h.Nonce, h.BodyDigest); err != nil {
		return err
	}
	seconds, err := strconv.ParseInt(h.Timestamp, 10, 64)
	if err != nil || h.ServiceID != expectedService || now.Sub(time.Unix(seconds, 0)) > 60*time.Second || time.Unix(seconds, 0).Sub(now) > 60*time.Second || len(h.Signature) > 128 || h.Signature == "" {
		return ErrCorpusTrust
	}
	encoded := strings.ReplaceAll(strings.ReplaceAll(h.Signature, "-", "+"), "_", "/")
	if remainder := len(encoded) % 4; remainder != 0 {
		encoded += strings.Repeat("=", 4-remainder)
	}
	signature, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return ErrCorpusTrust
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(corpusMessage(h, method, target))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return ErrCorpusTrust
	}
	return nil
}
