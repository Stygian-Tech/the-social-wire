package podcastcore

import "encoding/json"

type SearchResponse struct {
	Shows          []Show               `json:"shows"`
	Episodes       []Episode            `json:"episodes"`
	Cursor         *string              `json:"cursor,omitempty"`
	Candidates     []DirectoryCandidate `json:"candidates"`
	DirectoryLimit *int                 `json:"directoryLimit,omitempty"`
	HasMore        bool                 `json:"hasMore"`
}

func (v *SearchResponse) UnmarshalJSON(data []byte) error {
	type plain SearchResponse
	var decoded plain
	if err := decodeRequired(data, &decoded, "shows", "episodes", "hasMore"); err != nil {
		return err
	}
	*v = SearchResponse(decoded)
	if v.Shows == nil {
		v.Shows = []Show{}
	}
	if v.Episodes == nil {
		v.Episodes = []Episode{}
	}
	if v.Candidates == nil {
		v.Candidates = []DirectoryCandidate{}
	}
	return nil
}

func (v SearchResponse) MarshalJSON() ([]byte, error) {
	type plain SearchResponse
	if v.Shows == nil {
		v.Shows = []Show{}
	}
	if v.Episodes == nil {
		v.Episodes = []Episode{}
	}
	if v.Candidates == nil {
		v.Candidates = []DirectoryCandidate{}
	}
	return json.Marshal(plain(v))
}
