package podcastcore

import "encoding/json"

type Show struct {
	ID                string   `json:"id"`
	Title             string   `json:"title"`
	Description       *string  `json:"description,omitempty"`
	ArtworkURL        *string  `json:"artworkUrl,omitempty"`
	FeedURL           *string  `json:"feedUrl,omitempty"`
	SourceKind        string   `json:"sourceKind"`
	SourceURI         *string  `json:"sourceUri,omitempty"`
	Guid              *string  `json:"guid,omitempty"`
	EpisodeCollection *string  `json:"episodeCollection,omitempty"`
	BridgeJobID       *string  `json:"bridgeJobId,omitempty"`
	BridgeStatus      *string  `json:"bridgeStatus,omitempty"`
	Visibility        *string  `json:"visibility,omitempty"`
	Hosts             []Person `json:"hosts"`
}

func (v *Show) UnmarshalJSON(data []byte) error {
	type plain Show
	var decoded plain
	if err := decodeRequired(data, &decoded, "id", "title", "sourceKind"); err != nil {
		return err
	}
	*v = Show(decoded)
	if v.Hosts == nil {
		v.Hosts = []Person{}
	}
	return nil
}

func (v Show) MarshalJSON() ([]byte, error) {
	type plain Show
	if v.Hosts == nil {
		v.Hosts = []Person{}
	}
	return json.Marshal(plain(v))
}
