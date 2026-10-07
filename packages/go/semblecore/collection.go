package semblecore

type Collection struct {
	URI         string  `json:"uri"`
	Name        string  `json:"name"`
	Description *string `json:"description,omitempty"`
	AccessType  *string `json:"accessType,omitempty"`
	CardCount   int     `json:"cardCount"`
	CreatedAt   *string `json:"createdAt,omitempty"`
	UpdatedAt   *string `json:"updatedAt,omitempty"`
}
