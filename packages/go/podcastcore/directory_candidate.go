package podcastcore

type DirectoryCandidate struct {
	Provider    string  `json:"provider"`
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Description *string `json:"description,omitempty"`
	ArtworkURL  *string `json:"artworkUrl,omitempty"`
	FeedURL     string  `json:"feedUrl"`
}

func (v *DirectoryCandidate) UnmarshalJSON(data []byte) error {
	type plain DirectoryCandidate
	var decoded plain
	if err := decodeRequired(data, &decoded, "provider", "id", "title", "feedUrl"); err != nil {
		return err
	}
	*v = DirectoryCandidate(decoded)
	return nil
}
