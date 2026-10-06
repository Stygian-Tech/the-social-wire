// Package gatewaycore contains repository-owned gateway helpers. Authentication
// must use a signature-verifying, issuer-bound verifier; these helpers do not
// authenticate an access token or a DPoP proof.
package gatewaycore

// Uses go-jose to parse a signed compact envelope without verifying its signature.
// Payloads remain raw JSON to preserve exact numbers. ATH hashing is a DPoP helper;
// neither operation authenticates the caller.

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"

	jose "github.com/go-jose/go-jose/v4"
)

var ErrMalformedJWT = errors.New("malformed compact JWT payload")

// Base64URLDecode accepts URL-safe base64 with optional padding for compatible compact-
// token fields.
func Base64URLDecode(value string) ([]byte, error) {
	value = strings.ReplaceAll(strings.ReplaceAll(value, "-", "+"), "_", "/")
	if remainder := len(value) % 4; remainder != 0 {
		value += strings.Repeat("=", 4-remainder)
	}
	return base64.StdEncoding.DecodeString(value)
}

// Base64URLEncode emits unpadded URL-safe base64.
func Base64URLEncode(value []byte) string { return base64.RawURLEncoding.EncodeToString(value) }

// AccessTokenATH returns the base64url SHA-256 access-token hash required by DPoP; it does
// not validate the token.
func AccessTokenATH(accessToken string) string {
	hash := sha256.Sum256([]byte(accessToken))
	return Base64URLEncode(hash[:])
}

// DecodePayload inspects an already verified token. A successful decode conveys
// no authentication result.
func DecodePayload(token string) (map[string]json.RawMessage, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, ErrMalformedJWT
	}
	parsed, err := jose.ParseSignedCompact(token, []jose.SignatureAlgorithm{
		jose.ES256, jose.ES384, jose.ES512, jose.EdDSA,
		jose.RS256, jose.RS384, jose.RS512, jose.PS256, jose.PS384, jose.PS512,
	})
	if err != nil {
		return nil, ErrMalformedJWT
	}
	data := parsed.UnsafePayloadWithoutVerification()
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil || object == nil {
		return nil, ErrMalformedJWT
	}
	return object, nil
}
