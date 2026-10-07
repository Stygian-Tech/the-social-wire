package semblecore

type Note struct {
	URI       *string `json:"uri,omitempty"`
	Text      string  `json:"text"`
	AuthorDID string  `json:"authorDid"`
	Editable  bool    `json:"editable"`
}
