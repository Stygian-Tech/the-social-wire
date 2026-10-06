// Package lexicons resolves schemas generated from canonical lexicon JSON.
package lexicons

// Loads independent copies of canonical Lexicon documents and resolves default, named, or
// relative definitions. Schema lookup does not validate a record against the schema; typed
// models and value validation remain migration work.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Document contains one canonical Lexicon ID and its raw definition schemas.
type Document struct {
	Lexicon int                        `json:"lexicon"`
	ID      string                     `json:"id"`
	Defs    map[string]json.RawMessage `json:"defs"`
}

// Documents decodes a fresh schema map on every call so caller mutations cannot alter the
// embedded registry.
func Documents() (map[string]Document, error) {
	var result map[string]Document
	err := json.Unmarshal([]byte(schemaBundle), &result)
	return result, err
}

// IDs returns sorted registered IDs, or nil if the embedded bundle cannot be decoded.
func IDs() []string {
	docs, err := Documents()
	if err != nil {
		return nil
	}
	ids := make([]string, 0, len(docs))
	for id := range docs {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Resolve returns a copied definition; missing fragments select main, and fragment-only
// references use base.
func Resolve(ref, base string) (json.RawMessage, error) {
	id, definition, hasFragment := strings.Cut(ref, "#")
	if !hasFragment {
		definition = "main"
	}
	if id == "" {
		id = base
	}
	docs, err := Documents()
	if err != nil {
		return nil, err
	}
	doc, ok := docs[id]
	if !ok {
		return nil, fmt.Errorf("unknown lexicon %s", id)
	}
	schema, ok := doc.Defs[definition]
	if !ok {
		return nil, fmt.Errorf("unknown lexicon definition %s#%s", id, definition)
	}
	return append(json.RawMessage(nil), schema...), nil
}
