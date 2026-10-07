package podcastcore

type TranscriptCue struct {
	StartSeconds float64  `json:"startSeconds"`
	EndSeconds   *float64 `json:"endSeconds,omitempty"`
	Text         string   `json:"text"`
}

func (v *TranscriptCue) UnmarshalJSON(data []byte) error {
	type plain TranscriptCue
	var decoded plain
	if err := decodeRequired(data, &decoded, "startSeconds", "text"); err != nil {
		return err
	}
	*v = TranscriptCue(decoded)
	return nil
}
