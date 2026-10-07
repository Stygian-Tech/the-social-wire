package podcasts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type Assets struct {
	Episode                func(context.Context, string, string) (*podcastcore.Episode, error)
	Show                   func(context.Context, string, string) (*podcastcore.Show, error)
	Clip                   func(context.Context, string, *string, bool) (*podcastcore.Clip, error)
	PublishedRecordMatches func(context.Context, podcastcore.Clip) (bool, error)
	Fetcher                MediaFetcher
	Embedded               *EmbeddedArtwork
	WorkerURL, Secret      string
	WorkerClient           *http.Client
}

var clipAssetID = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func assetError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": http.StatusText(status), "message": message})
}
func assetViewer(w http.ResponseWriter, r *http.Request) (string, bool) {
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		assetError(w, 401, "Authentication is required")
		return "", false
	}
	return auth.DID, true
}
func (a *Assets) PrivateAsset(w http.ResponseWriter, r *http.Request) {
	viewer, ok := assetViewer(w, r)
	if !ok {
		return
	}
	id := r.URL.Query().Get("clipId")
	if id == "" || a.Clip == nil {
		assetError(w, 404, "Clip not found")
		return
	}
	clip, e := a.Clip(r.Context(), id, &viewer, false)
	if assetStoreFailure(w, e) {
		return
	}
	if clip == nil || clip.Status != "complete" {
		assetError(w, 404, "Clip not found")
		return
	}
	a.proxyAsset(w, r, *clip, false)
}
func (a *Assets) PublicAsset(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("clipId")
	if id == "" || a.Clip == nil || a.PublishedRecordMatches == nil {
		assetError(w, 404, "Clip not found")
		return
	}
	clip, e := a.Clip(r.Context(), id, nil, true)
	if assetStoreFailure(w, e) {
		return
	}
	if clip == nil || clip.PublishedURI == nil {
		assetError(w, 404, "Clip not found")
		return
	}
	matches, e := a.PublishedRecordMatches(r.Context(), *clip)
	if e != nil || !matches {
		assetError(w, 404, "Clip not found")
		return
	}
	a.proxyAsset(w, r, *clip, true)
}
func (a *Assets) proxyAsset(w http.ResponseWriter, r *http.Request, clip podcastcore.Clip, public bool) {
	format := r.URL.Query().Get("format")
	if format != "audio" && format != "video" || !clipAssetID.MatchString(clip.ID) {
		assetError(w, 400, "Invalid asset format")
		return
	}
	if a.WorkerURL == "" || a.Secret == "" {
		assetError(w, 503, "Podcast assets are unavailable")
		return
	}
	filename := "audio.m4a"
	if format == "video" {
		filename = "audiogram.mp4"
	}
	path := "/internal/assets/"
	if public {
		path = "/assets/"
	}
	target := strings.TrimRight(a.WorkerURL, "/") + path + clip.ID + "/" + filename
	ctx, cancel := context.WithTimeout(r.Context(), 6*time.Hour)
	defer cancel()
	request, e := http.NewRequestWithContext(ctx, "GET", target, nil)
	if e != nil {
		assetError(w, 502, "Podcast asset could not be loaded")
		return
	}
	request.Header.Set("X-Podcast-Media-Secret", a.Secret)
	if value := r.Header.Get("Range"); value != "" {
		request.Header.Set("Range", value)
	}
	client := a.WorkerClient
	if client == nil {
		client = &http.Client{}
	}
	copy := *client
	copy.Timeout = 0
	copy.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	headerTimer := time.AfterFunc(30*time.Second, cancel)
	reply, e := copy.Do(request)
	headerTimer.Stop()
	if e != nil || ctx.Err() != nil {
		if reply != nil {
			reply.Body.Close()
		}
		assetError(w, 502, "Podcast asset could not be loaded")
		return
	}
	reply.Body = newIdleMediaBody(reply.Body, cancel, 60*time.Second)
	defer reply.Body.Close()
	streamAssetResponse(w, reply)
}
func streamAssetResponse(w http.ResponseWriter, reply *http.Response) {
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"} {
		if value := reply.Header.Get(name); value != "" {
			w.Header().Set(name, value)
		}
	}
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(reply.StatusCode)
	_, _ = io.Copy(w, reply.Body)
}

func assetStoreFailure(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, podcastcore.ErrPrivateStorageUnavailable) {
		assetError(w, 503, "Private Podcast Storage Is Unavailable")
	} else {
		assetError(w, 500, "Podcast storage is unavailable")
	}
	return true
}
