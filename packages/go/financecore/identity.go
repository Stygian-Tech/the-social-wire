package financecore

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
func InstrumentID(provider, nativeID string) string {
	return "fin_" + digest(provider + ":" + nativeID)[:32]
}
func SelectionRecordKey(kind, id string) string { return digest(kind + ":" + id) }
func uniqueSorted(values []string) []string {
	set := map[string]bool{}
	for _, v := range values {
		set[v] = true
	}
	result := make([]string, 0, len(set))
	for v := range set {
		result = append(result, v)
	}
	sort.Strings(result)
	return result
}
func PreferenceFingerprint(instruments, sectors []string) string {
	values := []string{}
	for _, v := range uniqueSorted(instruments) {
		values = append(values, "i:"+v)
	}
	for _, v := range uniqueSorted(sectors) {
		values = append(values, "s:"+v)
	}
	return digest(strings.Join(values, "\n"))
}
