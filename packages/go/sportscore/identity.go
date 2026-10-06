package sportscore

// Derives entity IDs and selection record keys independently of mutable presentation.
// Follow and mute share the same record identity; preference fingerprints include actions
// and deduplicate/sort selections.

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"
)

func digest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// EntityID hashes a stable seed into an sp_ identity independent of presentation fields.
func EntityID(seed string) string { return "sp_" + digest(seed)[:32] }

// Selection identity intentionally excludes action so a follow-to-mute change
// replaces the same PDS record.
func SelectionRecordKey(id string) string { return digest(id) }

// PreferenceFingerprint hashes sorted, deduplicated preferences so equivalent selections
// share a cache identity.
func PreferenceFingerprint(selections []Selection) string {
	set := map[string]bool{}
	for _, selection := range selections {
		set[selection.Action+":"+selection.Reference] = true
	}
	values := make([]string, 0, len(set))
	for value := range set {
		values = append(values, value)
	}
	sort.Strings(values)
	return digest(strings.Join(values, "\n"))
}
