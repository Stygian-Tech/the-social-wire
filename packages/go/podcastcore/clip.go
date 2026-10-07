package podcastcore

type Clip struct {
	ID              string   `json:"id"`
	EpisodeID       string   `json:"episodeId"`
	SourceURI       *string  `json:"sourceUri,omitempty"`
	JobID           *string  `json:"jobId,omitempty"`
	StartSeconds    float64  `json:"startSeconds"`
	EndSeconds      float64  `json:"endSeconds"`
	Title           string   `json:"title"`
	Status          string   `json:"status"`
	AudioURL        *string  `json:"audioUrl,omitempty"`
	VideoURL        *string  `json:"videoUrl,omitempty"`
	PublicAudioURL  *string  `json:"publicAudioUrl,omitempty"`
	PublicVideoURL  *string  `json:"publicVideoUrl,omitempty"`
	AudioKey        *string  `json:"audioKey,omitempty"`
	VideoKey        *string  `json:"videoKey,omitempty"`
	DurationSeconds *float64 `json:"durationSeconds,omitempty"`
	PublishedURI    *string  `json:"publishedUri,omitempty"`
	CreatedAt       string   `json:"createdAt"`
}

func (v *Clip) UnmarshalJSON(data []byte) error {
	type plain Clip
	var decoded plain
	if err := decodeRequired(data, &decoded, "id", "episodeId", "startSeconds", "endSeconds", "title", "status", "createdAt"); err != nil {
		return err
	}
	*v = Clip(decoded)
	return nil
}
