package sportscore

import (
	"encoding/json"
)

func (e *Event) UnmarshalJSON(data []byte) error {
	type raw Event
	var value raw
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	*e = Event(value)
	e.decodedJSON = true
	field, exists := fields["startTimeKnown"]
	e.startTimeKnownPresent = exists && string(field) != "null"
	return nil
}
func (e Event) MarshalJSON() ([]byte, error) {
	type raw Event
	data, err := json.Marshal(raw(e))
	if err != nil || !e.decodedJSON || e.startTimeKnownPresent {
		return data, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	delete(fields, "startTimeKnown")
	return json.Marshal(fields)
}
