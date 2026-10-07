package semblecore

type Connection struct {
	URI            *string `json:"uri,omitempty"`
	Source         string  `json:"source"`
	Target         string  `json:"target"`
	ConnectionType *string `json:"connectionType,omitempty"`
	Note           *string `json:"note,omitempty"`
	CreatedAt      *string `json:"createdAt,omitempty"`
	UpdatedAt      *string `json:"updatedAt,omitempty"`
	AuthorDID      string  `json:"authorDid"`
	Editable       bool    `json:"editable"`
}
