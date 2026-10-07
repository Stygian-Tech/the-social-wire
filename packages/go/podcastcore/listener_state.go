package podcastcore

import "encoding/json"

type ListenerState struct {
	Subscriptions  []string            `json:"subscriptions"`
	Queue          []string            `json:"queue"`
	Progress       map[string]Progress `json:"progress"`
	PlaybackSpeed  float64             `json:"playbackSpeed"`
	RemoveSilences bool                `json:"removeSilences"`
	ManualLinks    []ManualLink        `json:"manualLinks"`
}

func (v *ListenerState) UnmarshalJSON(data []byte) error {
	type plain ListenerState
	var decoded plain
	if err := decodeRequired(data, &decoded, "subscriptions", "queue", "progress", "playbackSpeed", "removeSilences", "manualLinks"); err != nil {
		return err
	}
	*v = ListenerState(decoded)
	if v.Subscriptions == nil {
		v.Subscriptions = []string{}
	}
	if v.Queue == nil {
		v.Queue = []string{}
	}
	if v.ManualLinks == nil {
		v.ManualLinks = []ManualLink{}
	}
	return nil
}

func (v ListenerState) MarshalJSON() ([]byte, error) {
	type plain ListenerState
	if v.Subscriptions == nil {
		v.Subscriptions = []string{}
	}
	if v.Queue == nil {
		v.Queue = []string{}
	}
	if v.ManualLinks == nil {
		v.ManualLinks = []ManualLink{}
	}
	if v.Progress == nil {
		v.Progress = map[string]Progress{}
	}
	return json.Marshal(plain(v))
}
