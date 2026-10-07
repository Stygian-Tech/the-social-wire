package podcasts

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type Routes struct {
	Service *Service
	Assets  *Assets
}
type handler func(http.ResponseWriter, *http.Request, gatewaycore.AuthContext) error

func (a Routes) Register(mux *http.ServeMux) {
	routes := map[string]handler{"POST /v1/podcasts/search": a.search, "POST /v1/podcasts/resolve": a.resolve, "GET /v1/podcasts/shows": a.shows, "GET /v1/podcasts/episodes": a.episodes, "GET /v1/podcasts/state": a.state, "PUT /v1/podcasts/state": a.saveState, "GET /v1/podcasts/transcript": a.transcript, "POST /v1/podcasts/analysis": a.createAnalysis, "GET /v1/podcasts/analysis": a.analysis, "GET /v1/podcasts/jobs": a.job, "POST /v1/podcasts/jobs": a.retry, "POST /v1/podcasts/clips": a.createClip, "GET /v1/podcasts/clips": a.clips, "POST /v1/podcasts/clips/publish": a.publish, "DELETE /v1/podcasts/clips": a.removeClip, "POST /v1/podcasts/private/resolve": a.resolvePrivate, "POST /v1/podcasts/private/refresh": a.refreshPrivate, "DELETE /v1/podcasts/private/subscriptions": a.removePrivate}
	for pattern, handler := range routes {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			auth, ok := gatewaycore.AuthContextFrom(r.Context())
			if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
				podcastError(w, httpError(401, "Authentication is required"))
				return
			}
			if err := handler(w, r, auth); err != nil {
				podcastError(w, err)
			}
		})
	}
	if a.Assets != nil {
		mux.HandleFunc("GET /v1/podcasts/image", a.Assets.Image)
		mux.HandleFunc("GET /v1/podcasts/media", a.Assets.Media)
		mux.HandleFunc("GET /v1/podcasts/clips/asset", a.Assets.PrivateAsset)
	}
}
func (a Routes) RegisterPublic(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/podcasts/public/clips", func(w http.ResponseWriter, r *http.Request) {
		if err := a.publicClip(w, r); err != nil {
			podcastError(w, err)
		}
	})
	if a.Assets != nil {
		mux.HandleFunc("GET /v1/podcasts/public/clips/asset", a.Assets.PublicAsset)
	}
}
func podcastError(w http.ResponseWriter, err error) {
	var typed HTTPError
	status, message := 503, "Podcast Service Is Unavailable"
	if errors.As(err, &typed) {
		status, message = typed.Status, typed.Message
	} else if errors.Is(err, podcastcore.ErrPrivateStorageUnavailable) {
		message = "Private Podcast Storage Is Unavailable"
	} else if errors.Is(err, podcastcore.ErrRevisionConflict) {
		status, message = 409, "Podcast State Revision Conflict"
	} else if errors.Is(err, podcastcore.ErrInvalidState) {
		status, message = 400, "Invalid Podcast State"
	} else if errors.Is(err, podcastcore.ErrInvalidRequest) {
		status, message = 400, "Invalid Podcast Search"
	} else if errors.Is(err, podcastcore.ErrNotFound) {
		status, message = 404, "Not Found"
	}
	assetError(w, status, message)
}
func decodeBody[T any](r *http.Request, required ...string) (T, error) {
	var zero T
	data, err := io.ReadAll(io.LimitReader(r.Body, 2*1024*1024+1))
	if err != nil || len(data) > 2*1024*1024 {
		return zero, httpError(400, "Invalid Request")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return zero, httpError(400, "Invalid Request")
	}
	for _, key := range required {
		if value, ok := fields[key]; !ok || string(value) == "null" {
			return zero, httpError(400, "Invalid Request")
		}
	}
	if json.Unmarshal(data, &zero) != nil {
		return zero, httpError(400, "Invalid Request")
	}
	return zero, nil
}
func writeJSON(w http.ResponseWriter, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/json")
	_, err = w.Write(data)
	return err
}
func rawJSON(w http.ResponseWriter, raw string) error {
	w.Header().Set("Content-Type", "application/json")
	_, err := io.WriteString(w, raw)
	return err
}
func queryOptional(r *http.Request, key string) *string {
	values, ok := r.URL.Query()[key]
	if !ok {
		return nil
	}
	return &values[0]
}
func (a Routes) search(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	input, err := decodeBody[podcastcore.SearchRequest](r, "query")
	if err != nil {
		return err
	}
	var result podcastcore.SearchResponse
	if input.Scope != nil && *input.Scope == "directory" {
		if a.Service.Directory == nil {
			return httpError(502, "Podcast Index Is Unavailable. Try Again Shortly.")
		}
		result, err = a.Service.Directory.Search(r.Context(), input)
	} else {
		result, err = a.Service.Store.Search(r.Context(), auth.DID, input)
	}
	if errors.Is(err, ErrDirectoryInvalidQuery) {
		return httpError(400, "Discover Accepts Podcast Names Or Topics. Add Feed URLs Using Add Podcast.")
	}
	if errors.Is(err, ErrDirectoryInvalidRequest) {
		return httpError(400, "Invalid Podcast Directory Search")
	}
	if errors.Is(err, ErrDirectoryBusy) {
		return httpError(503, "Podcast Directory Is Busy. Try Again Shortly.")
	}
	if errors.Is(err, ErrDirectoryUnavailable) {
		return httpError(502, "Podcast Index Is Unavailable. Try Again Shortly.")
	}
	if err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "private, no-store")
	return writeJSON(w, result)
}
func (a Routes) resolve(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		URL string `json:"url"`
	}](r, "url")
	if err != nil {
		return err
	}
	result, err := a.Service.Resolve(r.Context(), body.URL)
	if err != nil {
		return err
	}
	return writeJSON(w, result)
}
func (a Routes) shows(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	shows, err := a.Service.Hydrate(r.Context(), auth)
	if err != nil {
		return err
	}
	snapshot, err := a.Service.Store.State(r.Context(), auth.DID)
	if err != nil {
		return err
	}
	hidden := map[string]bool{}
	for _, link := range snapshot.State.ManualLinks {
		hidden[link.ProtocolShowID] = true
	}
	visible := []podcastcore.Show{}
	for _, show := range shows {
		if !hidden[show.ID] {
			visible = append(visible, show)
		}
	}
	return writeJSON(w, map[string]any{"shows": visible})
}
func episodeResponse(w http.ResponseWriter, items []podcastcore.Episode, limit int) error {
	response := map[string]any{"episodes": items}
	if len(items) == limit && len(items) > 0 {
		response["cursor"] = items[len(items)-1].ID
	}
	return writeJSON(w, response)
}
func (a Routes) episodes(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	ctx := r.Context()
	viewer := auth.DID
	query := r.URL.Query()
	limit := 50
	if value, err := strconv.Atoi(query.Get("limit")); err == nil {
		limit = max(1, min(value, 100))
	}
	cursor := queryOptional(r, "cursor")
	var items []podcastcore.Episode
	var err error
	embedded := false
	responseLimit := limit
	if id := queryOptional(r, "episodeId"); id != nil {
		e, err := a.Service.Episode(ctx, *id, viewer)
		if err != nil {
			return err
		}
		if e == nil {
			return httpError(404, "Not Found")
		}
		items = []podcastcore.Episode{*e}
		embedded = true
		responseLimit = 2
	} else if query.Get("queue") == "true" {
		items, err = a.Service.Store.QueuedEpisodes(ctx, viewer)
		responseLimit = int(^uint(0) >> 1)
	} else if id := queryOptional(r, "showId"); id == nil {
		items, err = a.Service.Store.SubscribedEpisodes(ctx, viewer, cursor, limit)
	} else if podcastcore.IsPrivateID(*id) {
		show, err := a.Service.Store.PrivateShow(ctx, viewer, *id)
		if err != nil {
			return err
		}
		if show == nil {
			return httpError(404, "Not Found")
		}
		items, err = a.Service.Store.PrivateEpisodes(ctx, viewer, *id, cursor, limit)
	} else {
		show, err := a.Service.Store.Show(ctx, *id)
		if err != nil {
			return err
		}
		if show == nil {
			return httpError(404, "Not Found")
		}
		items, err = a.Service.Store.Episodes(ctx, show.ID, cursor, limit)
		if err != nil {
			return err
		}
		snapshot, err := a.Service.Store.State(ctx, viewer)
		if err != nil {
			return err
		}
		links := []podcastcore.ManualLink{}
		for _, link := range snapshot.State.ManualLinks {
			if link.RSSShowID == show.ID {
				links = append(links, link)
				native, err := a.Service.Store.Episodes(ctx, link.ProtocolShowID, cursor, limit)
				if err != nil {
					return err
				}
				items = append(items, native...)
			}
		}
		aliases, err := a.Service.Store.ManualEpisodeAliases(ctx, links)
		if err != nil {
			return err
		}
		for i := range items {
			if canonical, ok := aliases[items[i].ID]; ok {
				items[i].ID = canonical
			}
		}
		sort.SliceStable(items, func(i, j int) bool {
			if items[i].PublishedAt == items[j].PublishedAt {
				return items[i].ID > items[j].ID
			}
			return items[i].PublishedAt > items[j].PublishedAt
		})
		seen := map[string]bool{}
		dedup := []podcastcore.Episode{}
		for _, e := range items {
			identity := e.ID
			if e.Guid != nil {
				identity = *e.Guid
			}
			if !seen[identity] {
				seen[identity] = true
				dedup = append(dedup, e)
			}
		}
		items = dedup[:min(len(dedup), limit)]
	}
	if err != nil {
		return err
	}
	items = a.Service.Enrich(ctx, items, &viewer, true, embedded)
	for i := range items {
		items[i] = visibleEpisode(items[i])
	}
	return episodeResponse(w, items, responseLimit)
}
func (a Routes) state(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	shows, err := a.Service.Hydrate(r.Context(), auth)
	if err != nil {
		return err
	}
	snapshot, err := a.Service.Store.State(r.Context(), auth.DID)
	if err != nil {
		return err
	}
	snapshot.State.Subscriptions = []string{}
	for _, show := range shows {
		snapshot.State.Subscriptions = append(snapshot.State.Subscriptions, show.ID)
	}
	snapshot.State, err = a.Service.CanonicalState(r.Context(), snapshot.State)
	if err != nil {
		return err
	}
	return writeJSON(w, snapshot)
}
func (a Routes) saveState(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	input, err := decodeBody[struct {
		ExpectedRevision int64                     `json:"expectedRevision"`
		State            podcastcore.ListenerState `json:"state"`
	}](r, "expectedRevision", "state")
	if err != nil {
		return err
	}
	if !input.State.Validate() {
		return podcastcore.ErrInvalidState
	}
	shows, err := a.Service.Store.Shows(r.Context(), auth.DID)
	if err != nil {
		return err
	}
	private, err := a.Service.Store.PrivateShows(r.Context(), auth.DID)
	if err != nil {
		return err
	}
	input.State.Subscriptions = []string{}
	for _, show := range append(shows, private...) {
		input.State.Subscriptions = append(input.State.Subscriptions, show.ID)
	}
	for _, link := range input.State.ManualLinks {
		rss, err := a.Service.Store.Show(r.Context(), link.RSSShowID)
		if err != nil {
			return err
		}
		native, err := a.Service.Store.Show(r.Context(), link.ProtocolShowID)
		if err != nil {
			return err
		}
		if rss == nil || rss.SourceKind != "rss" || native == nil || native.SourceKind != "atproto" {
			return httpError(400, "Invalid Podcast Link")
		}
	}
	input.State, err = a.Service.CanonicalState(r.Context(), input.State)
	if err != nil {
		return err
	}
	snapshot, err := a.Service.Store.SaveState(r.Context(), auth.DID, input.ExpectedRevision, input.State)
	if err != nil {
		return err
	}
	return writeJSON(w, snapshot)
}
func (a Routes) transcript(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	id := queryOptional(r, "episodeId")
	if id == nil {
		return httpError(404, "Not Found")
	}
	episode, err := a.Service.Episode(r.Context(), *id, auth.DID)
	if err != nil {
		return err
	}
	if episode == nil {
		return httpError(404, "Not Found")
	}
	transcripts, err := a.Service.Transcripts(r.Context(), *episode)
	if err != nil {
		return err
	}
	if episode.Visibility != nil && *episode.Visibility == "private" {
		for i := range transcripts {
			t := &transcripts[i]
			t.URL = ""
			if t.Text != nil {
				t.Text = pointer(podcastcore.VisibleText(*t.Text))
			}
			cues := []podcastcore.TranscriptCue{}
			if t.Cues != nil {
				cues = append(cues, (*t.Cues)...)
			}
			for j := range cues {
				cues[j].Text = podcastcore.VisibleText(cues[j].Text)
			}
			t.Cues = &cues
		}
	}
	return writeJSON(w, map[string]any{"episodeId": *id, "transcripts": transcripts})
}
func (a Routes) resolvePrivate(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		URL string `json:"url"`
	}](r, "url")
	if err != nil {
		return err
	}
	response, err := a.Service.ResolvePrivate(r.Context(), auth.DID, body.URL, false)
	if err != nil {
		return err
	}
	return writeJSON(w, response)
}
func (a Routes) refreshPrivate(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	body, err := decodeBody[struct {
		ShowID string `json:"showId"`
	}](r, "showId")
	if err != nil {
		return err
	}
	response, err := a.Service.RefreshPrivate(r.Context(), auth.DID, body.ShowID)
	if err != nil {
		return err
	}
	return writeJSON(w, response)
}
func (a Routes) removePrivate(w http.ResponseWriter, r *http.Request, auth gatewaycore.AuthContext) error {
	id := queryOptional(r, "showId")
	if id == nil {
		return httpError(404, "Not Found")
	}
	removed, err := a.Service.Store.RemovePrivateSubscription(r.Context(), auth.DID, *id)
	if err != nil {
		return err
	}
	if !removed {
		return httpError(404, "Not Found")
	}
	return writeJSON(w, map[string]any{})
}
func (a Routes) publicClip(w http.ResponseWriter, r *http.Request) error {
	id := queryOptional(r, "clipId")
	if id == nil {
		id = queryOptional(r, "uri")
	}
	if id == nil {
		return httpError(404, "Not Found")
	}
	clip, err := a.Service.Store.Clip(r.Context(), *id, nil, true)
	if err != nil {
		return err
	}
	if clip == nil || clip.PublishedURI == nil {
		return httpError(404, "Not Found")
	}
	record, err := a.Service.Record(r.Context(), *clip.PublishedURI)
	if err != nil || !MatchesClip(record, *clip) {
		return httpError(404, "Not Found")
	}
	return writeJSON(w, clip)
}

type JobPayload struct {
	Episode                  podcastcore.Episode `json:"episode"`
	Show                     *podcastcore.Show   `json:"show,omitempty"`
	ClipID                   *string             `json:"clipId,omitempty"`
	StartSeconds, EndSeconds *float64            `json:"-"`
	Title                    *string             `json:"title,omitempty"`
	SourceFingerprint        *string             `json:"sourceFingerprint,omitempty"`
}

func (p JobPayload) MarshalJSON() ([]byte, error) {
	type plain JobPayload
	return json.Marshal(struct {
		plain
		Start *float64 `json:"startSeconds,omitempty"`
		End   *float64 `json:"endSeconds,omitempty"`
	}{plain(p), p.StartSeconds, p.EndSeconds})
}
