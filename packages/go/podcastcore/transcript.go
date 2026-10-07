package podcastcore

type Transcript struct {
	URL      string           `json:"url"`
	Type     string           `json:"type"`
	Language *string          `json:"language,omitempty"`
	Text     *string          `json:"text,omitempty"`
	Cues     *[]TranscriptCue `json:"cues,omitempty"`
}

func (v *Transcript) UnmarshalJSON(data []byte) error {
	type plain Transcript
	var decoded plain
	if err := decodeRequired(data, &decoded, "url", "type"); err != nil {
		return err
	}
	*v = Transcript(decoded)
	return nil
}
