package corpuscore

import (
	"bytes"
	"encoding/json"
	"math"
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
	return json.Marshal(httpDates(raw, reflect.ValueOf(value)))
}
func httpDates(raw any, v reflect.Value) any {
	if !v.IsValid() || raw == nil {
		return raw
	}
	for v.Kind() == reflect.Pointer || v.Kind() == reflect.Interface {
		if v.IsNil() {
			return raw
		}
		v = v.Elem()
	}
	t := v.Type()
	if t == reflect.TypeFor[time.Time]() {
		if text, ok := raw.(string); ok {
			if date, err := time.Parse(time.RFC3339Nano, text); err == nil {
				return date.UTC().Format(time.RFC3339)
			}
		}
		if number, ok := raw.(json.Number); ok {
			if value, err := number.Float64(); err == nil && !math.IsNaN(value) && !math.IsInf(value, 0) {
				whole, fraction := math.Modf(value)
				return time.Unix(978307200+int64(whole), int64(fraction*1e9)).UTC().Format(time.RFC3339)
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
					httpDates(raw, v.Field(i))
					continue
				}
				if tag == "" {
					tag = field.Name
				}
				if value, exists := object[tag]; exists {
					object[tag] = httpDates(value, v.Field(i))
				}
			}
		}
	case reflect.Slice, reflect.Array:
		if values, ok := raw.([]any); ok {
			for i, value := range values {
				values[i] = httpDates(value, v.Index(i))
			}
		}
	case reflect.Map:
		if t.Key().Kind() != reflect.String {
			return raw
		}
		if values, ok := raw.(map[string]any); ok {
			for key, value := range values {
				values[key] = httpDates(value, v.MapIndex(reflect.ValueOf(key).Convert(t.Key())))
			}
		}
	}
	return raw
}
