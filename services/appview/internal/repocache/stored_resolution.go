package repocache

import (
	"encoding/json"
	"errors"
)

// Swift's synthesized Codable associated-value enum is retained for mixed-runtime caches.
type storedResolution struct{ Endpoint string }

func (v storedResolution) MarshalJSON() ([]byte, error) {
	if v.Endpoint == "" {
		return []byte(`{"unresolved":{}}`), nil
	}
	return json.Marshal(map[string]any{"resolved": map[string]string{"_0": v.Endpoint}})
}
func (v *storedResolution) UnmarshalJSON(data []byte) error {
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil || len(object) != 1 {
		return errors.New("malformed PDS resolution cache")
	}
	if raw, ok := object["resolved"]; ok {
		var value struct {
			Endpoint *string `json:"_0"`
		}
		if json.Unmarshal(raw, &value) != nil || value.Endpoint == nil || *value.Endpoint == "" {
			return errors.New("malformed PDS resolution cache")
		}
		v.Endpoint = *value.Endpoint
		return nil
	}
	if raw, ok := object["unresolved"]; ok {
		var value map[string]json.RawMessage
		if json.Unmarshal(raw, &value) == nil && value != nil {
			v.Endpoint = ""
			return nil
		}
	}
	return errors.New("malformed PDS resolution cache")
}
