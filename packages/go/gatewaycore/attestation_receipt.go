package gatewaycore

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const ReceiptHeader = "X-ATProto-Session-Attestation-Receipt"
const ReceiptRequiredHeader = "X-ATProto-Session-Attestation-Required"
const UpstreamPreparedHeader = "X-ATProto-Upstream-DPoP-Prepared"
const SessionDPoPHeader = "X-ATProto-Session-DPoP"
const SessionNonceHeader = "X-ATProto-Session-DPoP-Nonce"

var ErrReceipt = errors.New("invalid session attestation receipt")
var ErrReceiptExpired = errors.New("expired session attestation receipt")

type AttestationReceipt struct {
	secret []byte
	kid    string
}
type receiptClaims struct {
	ATH string `json:"ath"`
	EXP int64  `json:"exp"`
	IAT int64  `json:"iat"`
	JKT string `json:"jkt"`
	KID string `json:"kid"`
	SUB string `json:"sub"`
	V   int    `json:"v"`
}

func NewAttestationReceipt(secret string) (*AttestationReceipt, error) {
	if len(secret) < 32 || len(secret) > 4096 {
		return nil, ErrReceipt
	}
	hash := sha256.Sum256([]byte(secret))
	return &AttestationReceipt{[]byte(secret), Base64URLEncode(hash[:])[:16]}, nil
}
func validReceiptBinding(token, did, jkt string) bool {
	return len(token) <= 32768 && strings.HasPrefix(did, "did:") && len(did) <= 2048 && jkt != "" && len(jkt) <= 256
}
func (a *AttestationReceipt) Issue(token, did, jkt string, tokenExpiry, authorityExpiry, now time.Time) (string, error) {
	expiry := now.Add(60 * time.Second)
	if tokenExpiry.Before(expiry) {
		expiry = tokenExpiry
	}
	if authorityExpiry.Before(expiry) {
		expiry = authorityExpiry
	}
	if !expiry.After(now) || !validReceiptBinding(token, did, jkt) {
		return "", ErrReceipt
	}
	raw, e := json.Marshal(receiptClaims{AccessTokenATH(token), expiry.Unix(), now.Unix(), jkt, a.kid, did, 1})
	if e != nil {
		return "", e
	}
	body := Base64URLEncode(raw)
	mac := hmac.New(sha256.New, a.secret)
	mac.Write([]byte(body))
	return body + "." + Base64URLEncode(mac.Sum(nil)), nil
}
func (a *AttestationReceipt) Verify(receipt, token, did, jkt string, tokenExpiry, now time.Time) (time.Time, error) {
	if len(receipt) > 4096 || strings.Contains(receipt, ",") || !validReceiptBinding(token, did, jkt) {
		return time.Time{}, ErrReceipt
	}
	parts := strings.Split(strings.TrimSpace(receipt), ".")
	if len(parts) != 2 || len(parts[0]) > 3072 || len(parts[1]) > 128 {
		return time.Time{}, ErrReceipt
	}
	sig, e := Base64URLDecode(parts[1])
	if e != nil || len(sig) != 32 {
		return time.Time{}, ErrReceipt
	}
	mac := hmac.New(sha256.New, a.secret)
	mac.Write([]byte(parts[0]))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return time.Time{}, ErrReceipt
	}
	raw, e := Base64URLDecode(parts[0])
	if e != nil || len(raw) > 2048 {
		return time.Time{}, ErrReceipt
	}
	var c receiptClaims
	if json.Unmarshal(raw, &c) != nil || c.V != 1 || c.KID != a.kid || c.SUB != did || c.JKT != jkt || c.ATH != AccessTokenATH(token) || c.IAT > now.Add(5*time.Second).Unix() || c.EXP <= c.IAT || c.EXP > tokenExpiry.Unix() || c.EXP-c.IAT > 60 {
		return time.Time{}, ErrReceipt
	}
	expiry := time.Unix(c.EXP, 0)
	if !expiry.After(now) {
		return time.Time{}, ErrReceiptExpired
	}
	return expiry, nil
}
