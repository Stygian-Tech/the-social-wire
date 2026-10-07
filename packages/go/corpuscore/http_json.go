package corpuscore

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"time"
)

// MarshalHTTP preserves Swift ISO8601 second precision without changing numeric values.
// It visits only typed timestamps, so arbitrary publisher text remains untouched.
func MarshalHTTP(value any) ([]byte, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var raw any
	if err := decoder.Decode(&raw); err != nil {
		return nil, err
	}
	return json.Marshal(httpDates(raw, reflect.TypeOf(value)))
}
func httpDates(raw any, t reflect.Type) any {
	if t == nil || raw == nil {
		return raw
	}
	for t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == reflect.TypeFor[time.Time]() {
		if text, ok := raw.(string); ok {
			if date, err := time.Parse(time.RFC3339Nano, text); err == nil {
				return date.UTC().Format(time.RFC3339)
			}
		}
		return raw
	}
	switch t.Kind() {
	case reflect.Struct:
		if object, ok := raw.(map[string]any); ok {
			for i := 0; i < t.NumField(); i++ {
				field := t.Field(i)
				tag := strings.Split(field.Tag.Get("json"), ",")[0]
				if tag == "-" || field.PkgPath != "" {
					continue
				}
				if field.Anonymous && tag == "" {
					httpDates(raw, field.Type)
					continue
				}
				if tag == "" {
					tag = field.Name
				}
				if value, exists := object[tag]; exists {
					object[tag] = httpDates(value, field.Type)
				}
			}
		}
	case reflect.Slice, reflect.Array:
		if values, ok := raw.([]any); ok {
			for i, value := range values {
				values[i] = httpDates(value, t.Elem())
			}
		}
	case reflect.Map:
		if values, ok := raw.(map[string]any); ok {
			for key, value := range values {
				values[key] = httpDates(value, t.Elem())
			}
		}
	}
	return raw
}
