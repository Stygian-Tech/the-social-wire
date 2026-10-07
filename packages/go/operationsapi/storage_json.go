package operationsapi

import (
	"encoding/json"
	"errors"
	"math"
	"reflect"
	"strings"
	"time"
)

const swiftReferenceUnixSeconds int64 = 978307200

// WireTime reads existing Swift stored snapshots (seconds since 2001) as well as
// ISO-8601 API values. Public responses always emit the API date representation.
type WireTime struct{ time.Time }

func (t WireTime) MarshalJSON() ([]byte, error) { return t.Time.MarshalJSON() }
func (t *WireTime) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		return errors.New("stored Operations timestamp cannot be null")
	}
	if len(data) > 0 && data[0] == '"' {
		return t.Time.UnmarshalJSON(data)
	}
	var seconds float64
	if err := json.Unmarshal(data, &seconds); err != nil {
		return err
	}
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) || math.Abs(seconds) > float64(math.MaxInt64)/float64(time.Second) {
		return errors.New("invalid stored Operations timestamp")
	}
	whole, fraction := math.Modf(seconds)
	t.Time = time.Unix(swiftReferenceUnixSeconds+int64(whole), int64(math.Round(fraction*float64(time.Second)))).UTC()
	return nil
}

// Stored snapshots and alert webhooks used plain Swift JSONEncoder, whose date
// epoch is 2001. Preserve that format across the hard runtime handoff. Typed dates
// are converted; arbitrary strings and exact int64 counters are preserved.
func marshalStored(value any) ([]byte, error) {
	stored, err := storageValue(reflect.ValueOf(value))
	if err != nil {
		return nil, err
	}
	return json.Marshal(stored)
}
func storageValue(v reflect.Value) (any, error) {
	if !v.IsValid() {
		return nil, nil
	}
	for v.Kind() == reflect.Pointer || v.Kind() == reflect.Interface {
		if v.IsNil() {
			return nil, nil
		}
		v = v.Elem()
	}
	if v.Type() == reflect.TypeOf(time.Time{}) {
		instant := v.Interface().(time.Time)
		return float64(instant.Unix()-swiftReferenceUnixSeconds) + float64(instant.Nanosecond())/1e9, nil
	}
	if v.Type() == reflect.TypeOf(WireTime{}) {
		return storageValue(reflect.ValueOf(v.Interface().(WireTime).Time))
	}
	switch v.Kind() {
	case reflect.Struct:
		object := map[string]any{}
		t := v.Type()
		for i := 0; i < v.NumField(); i++ {
			field := t.Field(i)
			if field.PkgPath != "" {
				continue
			}
			tag := strings.Split(field.Tag.Get("json"), ",")
			name := tag[0]
			if name == "-" {
				continue
			}
			if name == "" {
				name = field.Name
			}
			omit := false
			for _, option := range tag[1:] {
				if option == "omitempty" && v.Field(i).IsZero() {
					omit = true
				}
			}
			if omit {
				continue
			}
			value, err := storageValue(v.Field(i))
			if err != nil {
				return nil, err
			}
			object[name] = value
		}
		return object, nil
	case reflect.Map:
		if v.IsNil() {
			return nil, nil
		}
		if v.Type().Key().Kind() != reflect.String {
			return nil, errors.New("stored Operations JSON requires string map keys")
		}
		object := map[string]any{}
		iter := v.MapRange()
		for iter.Next() {
			value, err := storageValue(iter.Value())
			if err != nil {
				return nil, err
			}
			object[iter.Key().String()] = value
		}
		return object, nil
	case reflect.Slice, reflect.Array:
		if v.Kind() == reflect.Slice && v.IsNil() {
			return nil, nil
		}
		array := make([]any, v.Len())
		for i := 0; i < v.Len(); i++ {
			value, err := storageValue(v.Index(i))
			if err != nil {
				return nil, err
			}
			array[i] = value
		}
		return array, nil
	default:
		return v.Interface(), nil
	}
}
