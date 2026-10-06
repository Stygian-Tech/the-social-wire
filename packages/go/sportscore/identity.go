package sportscore

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
func EntityID(seed string) string { return "sp_" + digest(seed)[:32] }

// Selection identity intentionally excludes action so a follow-to-mute change
// replaces the same PDS record.
func SelectionRecordKey(id string) string { return digest(id) }
func PreferenceFingerprint(selections []Selection) string {
	set := map[string]bool{}
	for _, s := range selections {
		set[s.Action+":"+s.Reference] = true
	}
	values := make([]string, 0, len(set))
	for v := range set {
		values = append(values, v)
	}
	sort.Strings(values)
	return digest(strings.Join(values, "\n"))
}
