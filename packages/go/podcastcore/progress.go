package podcastcore

type Progress struct {
	PositionSeconds float64 `json:"positionSeconds"`
	UpdatedAt       string  `json:"updatedAt"`
	Completed       bool    `json:"completed"`
}

func (v *Progress) UnmarshalJSON(data []byte) error {
	type plain Progress
	var decoded plain
	if err := decodeRequired(data, &decoded, "positionSeconds", "updatedAt", "completed"); err != nil {
		return err
	}
	*v = Progress(decoded)
	return nil
}
