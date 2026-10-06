package readstatecore

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
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var v any
	err = d.Decode(&v)
	return v, err
}
func sortedSet(values []string) []string {
	seen := map[string]bool{}
	for _, v := range values {
		seen[v] = true
	}
	out := make([]string, 0, len(seen))
	for v := range seen {
		out = append(out, v)
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
	for _, p := range parts {
		if e := ValidateOperation(p); e != nil {
			return "", e
		}
		if p.ActionID != first.ActionID || p.Sequence != first.Sequence || p.State != first.State || p.ActedAt != first.ActedAt || p.Selection != first.Selection || !reflect.DeepEqual(p.Calendar, first.Calendar) {
			return "", ErrConflictingSequence
		}
	}
	base := map[string]any{"actionId": first.ActionID, "state": string(first.State), "actedAt": first.ActedAt, "selection": string(first.Selection)}
	if first.Calendar != nil {
		calendar, e := jsonValue(first.Calendar)
		if e != nil {
			return "", e
		}
		base["calendar"] = calendar
	}
	if first.Selection == Exact {
		var subjects []string
		for _, p := range parts {
			subjects = append(subjects, p.SubjectURIs...)
		}
		values := []any{}
		for _, v := range sortedSet(subjects) {
			values = append(values, v)
		}
		base["subjectUris"] = values
	} else {
		byKey := map[string]any{}
		for _, p := range parts {
			for _, b := range p.Boundaries {
				b.Scope.PublicationSiteKeys = sortedSet(b.Scope.PublicationSiteKeys)
				v, e := jsonValue(b)
				if e != nil {
					return "", e
				}
				data, e := CanonicalBytes(v)
				if e != nil {
					return "", e
				}
				byKey[hex.EncodeToString(data)] = v
			}
		}
		keys := make([]string, 0, len(byKey))
		for k := range byKey {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		values := []any{}
		for _, k := range keys {
			values = append(values, byKey[k])
		}
		base["boundaries"] = values
	}
	return CanonicalHash([]any{"app.thesocialwire.read-state/original-intent/v2", base})
}
