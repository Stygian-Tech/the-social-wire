package semblecore

import (
	"encoding/base64"
	"encoding/json"
	"strings"
)

func parseURI(raw string) (did, collection, key string, ok bool) {
	if !strings.HasPrefix(raw, "at://") {
		return
	}
	p := strings.Split(strings.TrimPrefix(raw, "at://"), "/")
	if len(p) != 3 || !strings.HasPrefix(p[0], "did:") || p[1] == "" || p[2] == "" {
		return
	}
	return p[0], p[1], p[2], true
}
func Page(cursor *string) (int, error) {
	if cursor == nil {
		return 1, nil
	}
	if len(*cursor) > 8192 {
		return 0, Invalid("`cursor` is invalid.")
	}
	b, e := base64.RawURLEncoding.DecodeString(strings.TrimRight(strings.NewReplacer("+", "-", "/", "_").Replace(*cursor), "="))
	var v struct {
		Page int `json:"page"`
	}
	if e != nil || json.Unmarshal(b, &v) != nil || v.Page < 1 {
		return 0, Invalid("`cursor` is invalid.")
	}
	return v.Page, nil
}
func nextCursor(page map[string]any) *string {
	p := object(page, "pagination")
	if more, _ := p["hasMore"].(bool); !more {
		return nil
	}
	n, _ := p["currentPage"].(float64)
	b, _ := json.Marshal(map[string]int{"page": int(n) + 1})
	s := base64.RawURLEncoding.EncodeToString(b)
	return &s
}
