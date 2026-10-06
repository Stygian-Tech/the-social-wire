package wirecore

// Signs internal corpus requests with a versioned newline-delimited HMAC over service,
// timestamp, nonce, method, and complete target. v2 also binds a supplied body digest.
// Verification checks the expected service and a 60-second clock window; body comparison
// and replay storage belong to the receiver.

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

// CorpusServiceHeaders carries service identity, clock, nonce, signature, and optional v2
// body digest.
type CorpusServiceHeaders struct {
	ServiceID  string  `json:"serviceID"`
	Timestamp  string  `json:"timestamp"`
	Nonce      string  `json:"nonce"`
	Signature  string  `json:"signature"`
	BodyDigest *string `json:"bodyDigest,omitempty"`
}

// CorpusBodyDigest returns lowercase SHA-256 of the exact request body bytes.
func CorpusBodyDigest(body []byte) string {
	value := sha256.Sum256(body)
	return hex.EncodeToString(value[:])
}
func validateCorpusRequest(secret []byte, service, target, nonce string, digest *string) error {
	if len(secret) < 32 || !serviceIDPattern.MatchString(service) || !strings.HasPrefix(target, "/") || len(target) > 2048 || strings.ContainsAny(target, "#\r\n") || !corpusNoncePattern.MatchString(nonce) || digest != nil && !digestPattern.MatchString(*digest) {
		return ErrCorpusTrust
	}
	return nil
}
func corpusMessage(headers CorpusServiceHeaders, method, target string) []byte {
	version := "wire-corpus-v1"
	if headers.BodyDigest != nil {
		version = "wire-corpus-v2"
	}
	message := strings.Join([]string{version, headers.ServiceID, headers.Timestamp, headers.Nonce, strings.ToUpper(method), target}, "\n")
	if headers.BodyDigest != nil {
		message += "\n" + *headers.BodyDigest
	}
	return []byte(message)
}

// SignCorpusRequest signs the complete method/target and optional body digest, generating
// a random UUID nonce when omitted.
func SignCorpusRequest(secret []byte, service, method, target string, digest *string, now time.Time, nonce string) (CorpusServiceHeaders, error) {
	if nonce == "" {
		var nonceBytes [16]byte
		if _, err := rand.Read(nonceBytes[:]); err != nil {
			return CorpusServiceHeaders{}, err
		}
		nonceBytes[6] = nonceBytes[6]&15 | 64
		nonceBytes[8] = nonceBytes[8]&63 | 128
		nonce = fmt.Sprintf("%x-%x-%x-%x-%x", nonceBytes[:4], nonceBytes[4:6], nonceBytes[6:8], nonceBytes[8:10], nonceBytes[10:])
	}
	if err := validateCorpusRequest(secret, service, target, nonce, digest); err != nil {
		return CorpusServiceHeaders{}, err
	}
	headers := CorpusServiceHeaders{ServiceID: service, Timestamp: strconv.FormatInt(now.Unix(), 10), Nonce: nonce, BodyDigest: digest}
	mac := hmac.New(sha256.New, secret)
	mac.Write(corpusMessage(headers, method, target))
	headers.Signature = base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return headers, nil
}

// VerifyCorpusRequest verifies expected service, HMAC, and ±60-second clock window. The
// receiver must also compare the body digest and prevent replay.
func VerifyCorpusRequest(secret []byte, expectedService, method, target string, headers CorpusServiceHeaders, now time.Time) error {
	if err := validateCorpusRequest(secret, expectedService, target, headers.Nonce, headers.BodyDigest); err != nil {
		return err
	}
	seconds, err := strconv.ParseInt(headers.Timestamp, 10, 64)
	if err != nil || headers.ServiceID != expectedService || now.Sub(time.Unix(seconds, 0)) > 60*time.Second || time.Unix(seconds, 0).Sub(now) > 60*time.Second || len(headers.Signature) > 128 || headers.Signature == "" {
		return ErrCorpusTrust
	}
	encoded := strings.ReplaceAll(strings.ReplaceAll(headers.Signature, "-", "+"), "_", "/")
	if remainder := len(encoded) % 4; remainder != 0 {
		encoded += strings.Repeat("=", 4-remainder)
	}
	signature, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return ErrCorpusTrust
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(corpusMessage(headers, method, target))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return ErrCorpusTrust
	}
	return nil
}
