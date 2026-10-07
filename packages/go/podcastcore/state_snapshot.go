package podcastcore

type StateSnapshot struct {
	Revision int64         `json:"revision"`
	State    ListenerState `json:"state"`
}

func (v *StateSnapshot) UnmarshalJSON(data []byte) error {
	type plain StateSnapshot
	var decoded plain
	if err := decodeRequired(data, &decoded, "revision", "state"); err != nil {
		return err
	}
	*v = StateSnapshot(decoded)
	return nil
}
