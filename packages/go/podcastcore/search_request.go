package podcastcore

type SearchRequest struct {
	Query  string  `json:"query"`
	Scope  *string `json:"scope,omitempty"`
	Kind   *string `json:"kind,omitempty"`
	ShowID *string `json:"showId,omitempty"`
	Limit  *int    `json:"limit,omitempty"`
	Cursor *string `json:"cursor,omitempty"`
}

func (v *SearchRequest) UnmarshalJSON(data []byte) error {
	type plain SearchRequest
	var decoded plain
	if err := decodeRequired(data, &decoded, "query"); err != nil {
		return err
	}
	*v = SearchRequest(decoded)
	return nil
}
