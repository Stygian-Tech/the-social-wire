package sportscore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"time"
)

// ServingCatalogRevision matches AppView's ISO8601 sorted-key catalog fingerprint.
// The worker's versioned, numeric-date CatalogRevision is deliberately separate.
func ServingCatalogRevision(entities []Entity) (string, error) {
	values := append([]Entity{}, entities...)
	sort.Slice(values, func(i, j int) bool { return values[i].ID < values[j].ID })
	data, err := json.Marshal(values)
	if err != nil {
		return "", err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var raw []map[string]any
	if err = decoder.Decode(&raw); err != nil {
		return "", err
	}
	for i, e := range values {
		if relations, ok := raw[i]["memberships"].([]any); ok {
			for j, m := range e.Memberships {
				relation := relations[j].(map[string]any)
				relation["validFrom"] = m.ValidFrom.UTC().Format(time.RFC3339)
				if m.ValidUntil != nil {
					relation["validUntil"] = m.ValidUntil.UTC().Format(time.RFC3339)
				}
			}
		}
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err = encoder.Encode(raw); err != nil {
		return "", err
	}
	canonical := strings.ReplaceAll(strings.TrimSuffix(buffer.String(), "\n"), "/", "\\/")
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:]), nil
}
