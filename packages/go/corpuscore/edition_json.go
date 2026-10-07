package corpuscore

import (
	"encoding/json"
)

// Preserve explicit empty additive collections while omitting absent legacy fields.
func (e Edition) MarshalJSON() ([]byte, error) {
	data, err := json.Marshal(e.Edition)
	if err != nil {
		return nil, err
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	if e.SourceActorKeysByItemID != nil {
		fields["sourceActorKeysByItemID"], err = json.Marshal(e.SourceActorKeysByItemID)
		if err != nil {
			return nil, err
		}
	}
	if e.FallbackRows != nil {
		fields["fallbackRows"], err = json.Marshal(e.FallbackRows)
		if err != nil {
			return nil, err
		}
	}
	return json.Marshal(fields)
}
