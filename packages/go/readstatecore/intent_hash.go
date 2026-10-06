package readstatecore

// Hashes a logical action independently of assigned sequence. Split parts must agree on
// action metadata; exact subjects and boundary selectors are deduplicated and sorted
// before a v2 domain-separated canonical hash is computed.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"sort"
)

func jsonValue(value any) (any, error) {
	data, err := EncodedBytes(value)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var decodedValue any
	err = decoder.Decode(&decodedValue)
	return decodedValue, err
}
func sortedSet(values []string) []string {
	seen := map[string]bool{}
	for _, value := range values {
		seen[value] = true
	}
	out := make([]string, 0, len(seen))
	for value := range seen {
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}

// OriginalIntentHash excludes assigned sequence and canonicalizes split selectors.
func OriginalIntentHash(parts []Operation) (string, error) {
	if len(parts) == 0 {
		return "", ErrInvalidRecord
	}
	first := parts[0]
	for _, part := range parts {
		if err := ValidateOperation(part); err != nil {
			return "", err
		}
		if part.ActionID != first.ActionID || part.Sequence != first.Sequence || part.State != first.State || part.ActedAt != first.ActedAt || part.Selection != first.Selection || !reflect.DeepEqual(part.Calendar, first.Calendar) {
			return "", ErrConflictingSequence
		}
	}
	base := map[string]any{"actionId": first.ActionID, "state": string(first.State), "actedAt": first.ActedAt, "selection": string(first.Selection)}
	if first.Calendar != nil {
		calendar, err := jsonValue(first.Calendar)
		if err != nil {
			return "", err
		}
		base["calendar"] = calendar
	}
	if first.Selection == Exact {
		var subjects []string
		for _, part := range parts {
			subjects = append(subjects, part.SubjectURIs...)
		}
		values := []any{}
		for _, value := range sortedSet(subjects) {
			values = append(values, value)
		}
		base["subjectUris"] = values
	} else {
		byKey := map[string]any{}
		for _, part := range parts {
			for _, boundary := range part.Boundaries {
				boundary.Scope.PublicationSiteKeys = sortedSet(boundary.Scope.PublicationSiteKeys)
				value, err := jsonValue(boundary)
				if err != nil {
					return "", err
				}
				data, err := CanonicalBytes(value)
				if err != nil {
					return "", err
				}
				byKey[hex.EncodeToString(data)] = value
			}
		}
		keys := make([]string, 0, len(byKey))
		for key := range byKey {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		values := []any{}
		for _, key := range keys {
			values = append(values, byKey[key])
		}
		base["boundaries"] = values
	}
	return CanonicalHash([]any{"app.thesocialwire.read-state/original-intent/v2", base})
}
