// Package socialwireredis provides disposable caches with the Swift wire format.
package socialwireredis

// Scopes disposable cache keys by environment, version, and domain. Raw identifiers are
// SHA-256 digests; bounded safe components remain readable, with unsafe or oversized
// components hashed to avoid ambiguous key structure.

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"unicode"
	"unicode/utf8"
)

// KeyNamespace separates cache keys by normalized environment and schema version.
type KeyNamespace struct{ Environment, Version string }

// NewKeyNamespace normalizes namespace components and defaults an empty version to v1.
func NewKeyNamespace(environment, version string) KeyNamespace {
	if version == "" {
		version = "v1"
	}
	return KeyNamespace{sanitize(environment), sanitize(version)}
}

// Digest returns a lowercase SHA-256 identifier digest; it is not keyed anonymization.
func Digest(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}
func sanitize(value string) string {
	value = strings.Map(func(character rune) rune {
		if unicode.IsLetter(character) || unicode.IsNumber(character) || character == '-' || character == '_' {
			return character
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

// Key joins sanitized domain/components and hashed identifiers into an environment-scoped
// cache key.
func (namespace KeyNamespace) Key(domain string, safeComponents, identifiers []string) string {
	parts := []string{"sw", namespace.Environment, namespace.Version, sanitize(domain)}
	for _, text := range safeComponents {
		parts = append(parts, boundedSafe(text))
	}
	for _, id := range identifiers {
		parts = append(parts, Digest(id))
	}
	return strings.Join(parts, ":")
}

// Pattern returns the namespace/identifier prefix followed by a Redis wildcard.
func (namespace KeyNamespace) Pattern(domain string, identifiers []string) string {
	return namespace.Key(domain, nil, identifiers) + ":*"
}
