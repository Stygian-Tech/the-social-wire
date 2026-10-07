package podcastcore

type Chapter struct {
	StartSeconds float64 `json:"startSeconds"`
	Title        string  `json:"title"`
	ArtworkURL   *string `json:"artworkUrl,omitempty"`
	URL          *string `json:"url,omitempty"`
}

func (v *Chapter) UnmarshalJSON(data []byte) error {
	type plain Chapter
	var decoded plain
	if err := decodeRequired(data, &decoded, "startSeconds", "title"); err != nil {
		return err
	}
	*v = Chapter(decoded)
	return nil
}
