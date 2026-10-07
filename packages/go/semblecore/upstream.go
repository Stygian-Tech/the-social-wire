package semblecore

import (
	"encoding/json"
	"math"
)

func object(m map[string]any, k string) map[string]any { v, _ := m[k].(map[string]any); return v }
func str(m map[string]any, k string) string            { v, _ := m[k].(string); return v }
func opt(m map[string]any, k string) *string {
	v, ok := m[k].(string)
	if !ok {
		return nil
	}
	return &v
}
func arr(m map[string]any, k string) []any { v, _ := m[k].([]any); return v }
func eq(a, b *string) bool                 { return (a == nil && b == nil) || (a != nil && b != nil && *a == *b) }
func required(m map[string]any, k, kind string) bool {
	v, ok := m[k]
	if !ok || v == nil {
		return false
	}
	switch kind {
	case "string":
		_, ok = v.(string)
	case "object":
		_, ok = v.(map[string]any)
	case "array":
		_, ok = v.([]any)
	case "bool":
		_, ok = v.(bool)
	case "int":
		n, yes := v.(float64)
		ok = yes && math.Trunc(n) == n && n >= -9007199254740991 && n <= 9007199254740991
	}
	return ok
}
func optionalStrings(m map[string]any, keys ...string) bool {
	for _, k := range keys {
		if v, ok := m[k]; ok && v != nil {
			if _, yes := v.(string); !yes {
				return false
			}
		}
	}
	return true
}
func user(m map[string]any) bool {
	return required(m, "id", "string") && optionalStrings(m, "name", "handle", "avatarUrl")
}
func collectionValid(m map[string]any) bool {
	return required(m, "id", "string") && required(m, "name", "string") && required(m, "cardCount", "int") && user(object(m, "author")) && optionalStrings(m, "uri", "description", "accessType", "createdAt", "updatedAt")
}
func cardValid(m map[string]any) bool {
	if !required(m, "id", "string") || !required(m, "type", "string") || !user(object(m, "author")) || !optionalStrings(m, "url", "uri", "cid", "createdAt") {
		return false
	}
	if v := m["cardContent"]; v != nil {
		o, ok := v.(map[string]any)
		if !ok || !optionalStrings(o, "url", "title", "description", "publishedDate", "siteName", "imageUrl") {
			return false
		}
	}
	if v := m["note"]; v != nil {
		o, ok := v.(map[string]any)
		if !ok || !required(o, "id", "string") || !required(o, "text", "string") {
			return false
		}
	}
	return true
}
func validatePage(m map[string]any, kind string) bool {
	p := object(m, "pagination")
	if !required(p, "currentPage", "int") || !required(p, "hasMore", "bool") {
		return false
	}
	switch kind {
	case "collections":
		if !required(m, "collections", "array") {
			return false
		}
		for _, v := range arr(m, "collections") {
			o, ok := v.(map[string]any)
			if !ok || !collectionValid(o) {
				return false
			}
		}
	case "collection":
		if !collectionValid(m) || !required(m, "urlCards", "array") {
			return false
		}
		for _, v := range arr(m, "urlCards") {
			o, ok := v.(map[string]any)
			if !ok || !cardValid(o) {
				return false
			}
		}
	case "connections":
		if !required(m, "connections", "array") {
			return false
		}
		for _, v := range arr(m, "connections") {
			o, ok := v.(map[string]any)
			if !ok {
				return false
			}
			c := object(o, "connection")
			if !required(c, "id", "string") || !user(object(c, "curator")) || !optionalStrings(c, "uri", "type", "note", "createdAt", "updatedAt") || !required(object(o, "source"), "url", "string") || !required(object(o, "target"), "url", "string") {
				return false
			}
		}
	}
	return true
}
func decodeRecord(r Record) map[string]any {
	var m map[string]any
	if json.Unmarshal(r.Value, &m) != nil {
		return nil
	}
	return m
}
func collectionDTO(m map[string]any, uri string) Collection {
	n, _ := m["cardCount"].(float64)
	return Collection{uri, str(m, "name"), opt(m, "description"), opt(m, "accessType"), int(n), opt(m, "createdAt"), opt(m, "updatedAt")}
}
