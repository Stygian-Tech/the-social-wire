package readstatecore

import "encoding/json"

// V2Fragment binds one retained selector fragment to its original device or legacy intent.
type V2Fragment struct {
	Operation
	Fragment      bool    `json:"fragment"`
	IntentHash    string  `json:"intentHash"`
	DeviceID      *string `json:"deviceId,omitempty"`
	DeviceCounter *int64  `json:"deviceCounter,omitempty"`
}

func (fragment *V2Fragment) UnmarshalJSON(data []byte) error {
	if err := closedOperation(data, true); err != nil {
		return err
	}
	type plain V2Fragment
	var value plain
	if json.Unmarshal(data, &value) != nil {
		return ErrInvalidRecord
	}
	*fragment = V2Fragment(value)
	return fragment.Validate()
}

// Validate requires a complete original identity and interoperable safe counters.
func (fragment V2Fragment) Validate() error {
	if err := ValidateOperation(fragment.Operation); err != nil {
		return err
	}
	if !fragment.Fragment || !hashPattern.MatchString(fragment.IntentHash) || (fragment.DeviceID == nil) != (fragment.DeviceCounter == nil) {
		return ErrInvalidRecord
	}
	if fragment.DeviceID != nil && (!devicePattern.MatchString(*fragment.DeviceID) || *fragment.DeviceCounter < 1 || *fragment.DeviceCounter > MaximumSequence) {
		return ErrInvalidRecord
	}
	return nil
}
