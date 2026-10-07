package publicationcore

type PreferenceRecord struct {
	URI           string         `json:"uri"`
	PublicationID string         `json:"publicationId"`
	Value         map[string]any `json:"value"`
}
