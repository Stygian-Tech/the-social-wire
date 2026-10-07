package readagecore

type OptionsResponse struct {
	Options      []Option `json:"options"`
	ReferenceDay string   `json:"referenceDay"`
}
