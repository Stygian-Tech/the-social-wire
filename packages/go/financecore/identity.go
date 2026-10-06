package financecore

// Derives stable instrument and PDS selection identifiers from provider-native identity,
// then fingerprints sorted, deduplicated preferences. Display names and input order cannot
// change these keys.

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

// InstrumentID hashes provider and native ID into a fin_ identifier; mutable names and
// tickers are excluded.
func InstrumentID(provider, nativeID string) string {
	return "fin_" + digest(provider + ":" + nativeID)[:32]
}

// SelectionRecordKey derives the deterministic PDS record key for the logical selection
// identity.
func SelectionRecordKey(kind, id string) string { return digest(kind + ":" + id) }
func uniqueSorted(values []string) []string {
	set := map[string]bool{}
	for _, value := range values {
		set[value] = true
	}
	result := make([]string, 0, len(set))
	for value := range set {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

// PreferenceFingerprint hashes sorted, deduplicated preferences so equivalent selections
// share a cache identity.
func PreferenceFingerprint(instruments, sectors []string) string {
	values := []string{}
	for _, value := range uniqueSorted(instruments) {
		values = append(values, "i:"+value)
	}
	for _, value := range uniqueSorted(sectors) {
		values = append(values, "s:"+value)
	}
	return digest(strings.Join(values, "\n"))
}
