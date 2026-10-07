package corpuscore

import (
	"bytes"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"reflect"
	"strings"
	"time"
)

// Swift Codable rejects missing required fields and null required collections. Preserve
// that behavior rather than allowing Go zero values to turn malformed data into success.
func decodeContract(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var raw any
	if decoder.Decode(&raw) != nil || !requiredFields(raw, reflect.TypeOf(destination)) {
		return ErrContractMismatch
	}
	if json.Unmarshal(data, destination) != nil {
		return ErrContractMismatch
	}
	return nil
}
func requiredFields(raw any, t reflect.Type) bool {
	if t == nil {
		return false
	}
	optional := t.Kind() == reflect.Pointer
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if raw == nil {
		return optional
	}
	if t == reflect.TypeFor[time.Time]() {
		return true
	}
	switch t.Kind() {
	case reflect.Struct:
		object, ok := raw.(map[string]any)
		if !ok {
			return false
		}
		for i := 0; i < t.NumField(); i++ {
			field := t.Field(i)
			if field.PkgPath != "" {
				continue
			}
			tag := strings.Split(field.Tag.Get("json"), ",")[0]
			if tag == "-" {
				continue
			}
			if field.Anonymous && tag == "" {
				if !requiredFields(raw, field.Type) {
					return false
				}
				continue
			}
			if tag == "" {
				tag = field.Name
			}
			value, exists := object[tag]
			optional := field.Type.Kind() == reflect.Pointer || strings.Contains(field.Tag.Get("json"), "omitempty") || (t == reflect.TypeFor[sportscore.Event]() && tag == "startTimeKnown")
			if !exists || value == nil {
				if optional {
					continue
				}
				return false
			}
			if !requiredFields(value, field.Type) {
				return false
			}
		}
		if t == reflect.TypeFor[wirecore.FeedItem]() {
			values, _ := object["provenance"].([]any)
			for _, value := range values {
				switch value {
				case "standard_site", "recommendation", "direct_share", "quote", "repost", "like", "rss":
				default:
					return false
				}
			}
		}
		return true
	case reflect.Slice, reflect.Array:
		values, ok := raw.([]any)
		if !ok {
			return false
		}
		for _, value := range values {
			if !requiredFields(value, t.Elem()) {
				return false
			}
		}
		return true
	case reflect.Map:
		values, ok := raw.(map[string]any)
		if !ok {
			return false
		}
		for _, value := range values {
			if !requiredFields(value, t.Elem()) {
				return false
			}
		}
		return true
	default:
		return true
	}
}
