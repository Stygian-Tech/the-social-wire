// Package socialwireredis provides disposable caches with the Swift wire format.
package socialwireredis

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"unicode"
	"unicode/utf8"
)

type KeyNamespace struct{ Environment, Version string }

func NewKeyNamespace(environment, version string) KeyNamespace {
	if version == "" {
		version = "v1"
	}
	return KeyNamespace{sanitize(environment), sanitize(version)}
}
func Digest(value string) string { d := sha256.Sum256([]byte(value)); return hex.EncodeToString(d[:]) }
func sanitize(value string) string {
	value = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, strings.ToLower(value))
	value = strings.Trim(value, "-")
	if value == "" {
		return "unknown"
	}
	return value
}
func boundedSafe(value string) string {
	normalized := sanitize(value)
	if utf8.RuneCountInString(value) > 64 || normalized != strings.ToLower(value) {
		return Digest(value)
	}
	return normalized
}
func (n KeyNamespace) Key(domain string, safeComponents, identifiers []string) string {
	parts := []string{"sw", n.Environment, n.Version, sanitize(domain)}
	for _, s := range safeComponents {
		parts = append(parts, boundedSafe(s))
	}
	for _, id := range identifiers {
		parts = append(parts, Digest(id))
	}
	return strings.Join(parts, ":")
}
func (n KeyNamespace) Pattern(domain string, identifiers []string) string {
	return n.Key(domain, nil, identifiers) + ":*"
}
