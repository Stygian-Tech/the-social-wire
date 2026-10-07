package podcasts

import (
	"math"
	"net/http"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type ClipRequest struct {
	EpisodeID       string  `json:"episodeId"`
	StartSeconds    float64 `json:"startSeconds"`
	EndSeconds      float64 `json:"endSeconds"`
	Title           *string `json:"title,omitempty"`
	IncludeCaptions *bool   `json:"includeCaptions,omitempty"`
}

func validClipRange(body ClipRequest, duration *float64) bool {
	return !math.IsNaN(body.StartSeconds) && !math.IsInf(body.StartSeconds, 0) && !math.IsNaN(body.EndSeconds) && !math.IsInf(body.EndSeconds, 0) && body.StartSeconds >= 0 && body.EndSeconds > body.StartSeconds && body.EndSeconds-body.StartSeconds <= 600 && body.EndSeconds*1000 < float64(math.MaxInt64) && (duration == nil || body.EndSeconds <= *duration)
}
func (a Routes) createClip(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[ClipRequest](r, "episodeId", "startSeconds", "endSeconds")
	if err != nil {
		return err
	}
	if podcastcore.IsPrivateID(body.EpisodeID) {
		episode, err := a.Service.Store.PrivateEpisode(r.Context(), auth.DID, body.EpisodeID)
		if err != nil {
			return err
		}
		if episode == nil {
			return httpError(404, "Not Found")
		}
		return httpError(403, "Clipping Private Podcasts Is Not Supported")
	}
	episode, err := a.Service.Store.Episode(r.Context(), body.EpisodeID)
	if err != nil {
		return err
	}
	if episode == nil || !validClipRange(body, episode.DurationSeconds) {
		return httpError(400, "Invalid Clip Range")
	}
	show, err := a.Service.Store.Show(r.Context(), episode.ShowID)
	if err != nil {
		return err
	}
	if show == nil {
		return httpError(400, "Invalid Clip Range")
	}
	if body.IncludeCaptions != nil && !*body.IncludeCaptions {
		episode.Transcripts = []podcastcore.Transcript{}
	} else {
		episode.Transcripts, err = a.Service.Transcripts(r.Context(), *episode)
		if err != nil {
			return err
		}
	}
	id, err := podcastcore.NewClipID()
	if err != nil {
		return err
	}
	title := episode.Title
	if body.Title != nil {
		title = *body.Title
	}
	clip := podcastcore.Clip{ID: id, EpisodeID: episode.ID, SourceURI: episode.SourceURI, StartSeconds: body.StartSeconds, EndSeconds: body.EndSeconds, Title: title, Status: "queued", CreatedAt: a.Service.now().UTC().Format(time.RFC3339)}
	payload, err := swiftJSON(JobPayload{Episode: *episode, Show: show, ClipID: &clip.ID, StartSeconds: &clip.StartSeconds, EndSeconds: &clip.EndSeconds, Title: &clip.Title})
	if err != nil {
		return err
	}
	job, err := a.Service.Store.PrepareClip(r.Context(), auth.DID, clip, payload)
	if err != nil {
		return err
	}
	return writeJSON(w, map[string]string{"clipId": clip.ID, "jobId": job, "status": "queued"})
}
func (a Routes) clips(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	clips, err := a.Service.Store.Clips(r.Context(), auth.DID)
	if err != nil {
		return err
	}
	return writeJSON(w, map[string]any{"clips": clips})
}
func (a Routes) publish(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		ClipID string `json:"clipId"`
		URI    string `json:"uri"`
	}](r, "clipId", "uri")
	if err != nil {
		return err
	}
	clip, err := a.Service.Store.Clip(r.Context(), body.ClipID, &auth.DID, false)
	if err != nil {
		return err
	}
	did, collection, _, valid := atParts(body.URI)
	if clip == nil || clip.Status != "complete" || !valid || did != auth.DID || collection != "app.thesocialwire.podcast.clip" {
		return httpError(400, "Clip Record Unavailable")
	}
	record, err := a.Service.Record(r.Context(), body.URI)
	if err != nil || record == nil {
		return httpError(400, "Clip Record Unavailable")
	}
	if !MatchesClip(record, *clip) {
		return httpError(400, "Clip Record Does Not Match Rendered Clip")
	}
	if err := a.Service.Store.PublishClip(r.Context(), clip.ID, auth.DID, body.URI); err != nil {
		return err
	}
	return writeJSON(w, map[string]string{"clipId": clip.ID, "uri": body.URI})
}
func MatchesClip(record map[string]any, clip podcastcore.Clip) bool {
	if record["$type"] != "app.thesocialwire.podcast.clip" || record["episodeId"] != clip.EpisodeID {
		return false
	}
	start, startOK := record["startMillis"].(float64)
	end, endOK := record["endMillis"].(float64)
	if !startOK || !endOK || start != math.Round(clip.StartSeconds*1000) || end != math.Round(clip.EndSeconds*1000) || start != math.Trunc(start) || end != math.Trunc(end) {
		return false
	}
	audio, audioOK := record["audioUrl"].(string)
	video, videoOK := record["videoUrl"].(string)
	if clip.PublicAudioURL == nil {
		if audioOK {
			return false
		}
	} else if !audioOK || audio != *clip.PublicAudioURL {
		return false
	}
	if clip.PublicVideoURL == nil {
		if videoOK {
			return false
		}
	} else if !videoOK || video != *clip.PublicVideoURL {
		return false
	}
	return true
}
func (a Routes) removeClip(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	id := queryOptional(r, "clipId")
	if id == nil {
		return httpError(404, "Not Found")
	}
	clip, err := a.Service.Store.Clip(r.Context(), *id, &auth.DID, false)
	if err != nil {
		return err
	}
	if clip == nil {
		return httpError(404, "Not Found")
	}
	audio, video := "clips/"+clip.ID+"/audio.m4a", "clips/"+clip.ID+"/audiogram.mp4"
	if clip.AudioKey != nil {
		audio = *clip.AudioKey
	}
	if clip.VideoKey != nil {
		video = *clip.VideoKey
	}
	payload, err := swiftJSON(map[string]string{"clipId": clip.ID, "audioKey": audio, "videoKey": video})
	if err != nil {
		return err
	}
	if err := a.Service.Store.RemoveClip(r.Context(), auth.DID, *clip, payload); err != nil {
		return err
	}
	return writeJSON(w, map[string]any{})
}
