package semblecore

type CollectionsResponse struct {
	Collections []Collection `json:"collections"`
	Cursor      *string      `json:"cursor,omitempty"`
}
