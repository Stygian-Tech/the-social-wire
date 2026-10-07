package podcasts

import (
	"encoding/json"
	"net/http"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

func (a Routes) createAnalysis(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		EpisodeID string `json:"episodeId"`
	}](r, "episodeId")
	if err != nil {
		return err
	}
	episode, err := a.Service.Episode(r.Context(), body.EpisodeID, auth.DID)
	if err != nil {
		return err
	}
	if episode == nil {
		return httpError(404, "Not Found")
	}
	if episode.Visibility != nil && *episode.Visibility == "private" {
		return httpError(403, "Silence Analysis Is Unavailable For Private Podcasts")
	}
	fingerprint, err := a.Service.Fingerprint(r.Context(), *episode)
	if err != nil {
		return err
	}
	payload, err := swiftJSON(JobPayload{Episode: *episode, SourceFingerprint: &fingerprint})
	if err != nil {
		return err
	}
	id, err := a.Service.Store.Enqueue(r.Context(), nil, &episode.ID, "silence", "silence:v2:"+episode.ID+":"+fingerprint, payload)
	if err != nil {
		return err
	}
	if _, err := a.Service.Store.Retry(r.Context(), auth.DID, id); err != nil {
		return err
	}
	job, err := a.Service.Store.Job(r.Context(), podcastcore.JobQuery{Viewer: auth.DID, JobID: &id, Kind: pointer("silence")})
	if err != nil {
		return err
	}
	if job == nil {
		return httpError(404, "Not Found")
	}
	return rawJSON(w, *job)
}
func unavailableAnalysis(w http.ResponseWriter, private bool) error {
	response := map[string]any{"analysisVersion": "v2", "status": "unavailable", "intervals": []any{}}
	if private {
		response["reason"] = "private-feed"
	}
	return writeJSON(w, response)
}
func (a Routes) analysis(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	id := queryOptional(r, "episodeId")
	if id == nil {
		return httpError(400, "Bad Request")
	}
	episode, err := a.Service.Episode(r.Context(), *id, auth.DID)
	if err != nil {
		return err
	}
	if episode == nil {
		return httpError(400, "Bad Request")
	}
	if episode.Visibility != nil && *episode.Visibility == "private" {
		return unavailableAnalysis(w, true)
	}
	fingerprint, err := a.Service.Fingerprint(r.Context(), *episode)
	if err != nil {
		return err
	}
	key := "silence:v2:" + *id + ":" + fingerprint
	raw, err := a.Service.Store.Job(r.Context(), podcastcore.JobQuery{Viewer: auth.DID, EpisodeID: id, Kind: pointer("silence"), Key: &key})
	if err != nil {
		return err
	}
	if raw == nil {
		return unavailableAnalysis(w, false)
	}
	var job map[string]any
	if json.Unmarshal([]byte(*raw), &job) != nil {
		return unavailableAnalysis(w, false)
	}
	result, _ := job["result"].(map[string]any)
	if job["status"] == "complete" && result["sourceFingerprint"] != fingerprint {
		if jobID, ok := job["id"].(string); ok {
			if err := a.Service.Store.InvalidateAnalysis(r.Context(), jobID, fingerprint); err != nil {
				return err
			}
		}
		return unavailableAnalysis(w, false)
	}
	status := job["status"]
	if status == nil {
		status = "unavailable"
	}
	intervals := result["intervals"]
	if intervals == nil {
		intervals = []any{}
	}
	return writeJSON(w, map[string]any{"analysisVersion": "v2", "status": status, "intervals": intervals})
}
func (a Routes) job(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	id, show, clip := queryOptional(r, "jobId"), queryOptional(r, "showId"), queryOptional(r, "clipId")
	if id == nil && show == nil && clip == nil {
		return httpError(404, "Not Found")
	}
	var kind *string
	if show != nil {
		kind = pointer("bridge")
	} else if clip != nil {
		kind = pointer("clip")
	}
	job, err := a.Service.Store.Job(r.Context(), podcastcore.JobQuery{Viewer: auth.DID, JobID: id, ShowID: show, ClipID: clip, Kind: kind})
	if err != nil {
		return err
	}
	if job == nil {
		return httpError(404, "Not Found")
	}
	return rawJSON(w, *job)
}
func (a Routes) retry(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		JobID string `json:"jobId"`
	}](r, "jobId")
	if err != nil {
		return err
	}
	retried, err := a.Service.Store.Retry(r.Context(), auth.DID, body.JobID)
	if err != nil {
		return err
	}
	if !retried {
		return httpError(409, "Job Cannot Be Retried")
	}
	job, err := a.Service.Store.Job(r.Context(), podcastcore.JobQuery{Viewer: auth.DID, JobID: &body.JobID})
	if err != nil {
		return err
	}
	if job == nil {
		return httpError(404, "Not Found")
	}
	return rawJSON(w, *job)
}
