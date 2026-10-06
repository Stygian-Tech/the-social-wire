// Package lexicons resolves schemas generated from canonical lexicon JSON.
package lexicons

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

type Document struct {
	Lexicon int                        `json:"lexicon"`
	ID      string                     `json:"id"`
	Defs    map[string]json.RawMessage `json:"defs"`
}

func Documents() (map[string]Document, error) {
	var result map[string]Document
	err := json.Unmarshal([]byte(schemaBundle), &result)
	return result, err
}
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
