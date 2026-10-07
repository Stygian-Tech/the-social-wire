package podcastcore

import "encoding/json"

type Episode struct {
	ID               string       `json:"id"`
	ShowID           string       `json:"showId"`
	Title            string       `json:"title"`
	Description      *string      `json:"description,omitempty"`
	PublishedAt      string       `json:"publishedAt"`
	AudioURL         string       `json:"audioUrl"`
	AudioMimeType    *string      `json:"audioMimeType,omitempty"`
	DurationSeconds  *float64     `json:"durationSeconds,omitempty"`
	ArtworkURL       *string      `json:"artworkUrl,omitempty"`
	Guid             *string      `json:"guid,omitempty"`
	SourceURI        *string      `json:"sourceUri,omitempty"`
	Transcripts      []Transcript `json:"transcripts"`
	Visibility       *string      `json:"visibility,omitempty"`
	Chapters         []Chapter    `json:"chapters"`
	ChapterSourceURL *string      `json:"chapterSourceUrl,omitempty"`
	ShowArtworkURL   *string      `json:"showArtworkUrl,omitempty"`
}

func (v *Episode) UnmarshalJSON(data []byte) error {
	type plain Episode
	var decoded plain
	if err := decodeRequired(data, &decoded, "id", "showId", "title", "publishedAt", "audioUrl", "transcripts"); err != nil {
		return err
	}
	*v = Episode(decoded)
	if v.Transcripts == nil {
		v.Transcripts = []Transcript{}
	}
	if v.Chapters == nil {
		v.Chapters = []Chapter{}
	}
	return nil
}

func (v Episode) MarshalJSON() ([]byte, error) {
	type plain Episode
	if v.Transcripts == nil {
		v.Transcripts = []Transcript{}
	}
	if v.Chapters == nil {
		v.Chapters = []Chapter{}
	}
	return json.Marshal(plain(v))
}
