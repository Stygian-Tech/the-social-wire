// Package media projects viewer-authorized Bluesky candidates without fetching,
// storing, or attributing those posts to another publishing application.
package media

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/url"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type Routes struct{}

type candidate struct {
	URI   string         `json:"uri"`
	Embed map[string]any `json:"embed"`
}

func (Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/media/project", project)
}

func project(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "private, no-store")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "Authentication Required"})
		return
	}
	var input struct {
		Mode  string      `json:"mode"`
		Posts []candidate `json:"posts"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || input.Mode != "photos" && input.Mode != "short-videos" || input.Posts == nil || len(input.Posts) > 30 {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "Invalid Media Candidates"})
		return
	}
	uris := []string{}
	seen := map[string]bool{}
	for _, post := range input.Posts {
		if validPostURI(post.URI) && !seen[post.URI] && matches(post.Embed, input.Mode, 0) {
			seen[post.URI] = true
			uris = append(uris, post.URI)
		}
	}
	selection := "images"
	if input.Mode == "short-videos" {
		selection = "portrait-video"
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"uris": uris, "source": "bluesky-following", "selection": selection, "durationVerified": false, "unsupportedSources": []string{"spark", "grain", "flashes-attribution"}})
}

func validPostURI(raw string) bool {
	if len(raw) > 2048 || !strings.HasPrefix(raw, "at://did:") {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(raw, "at://"), "/")
	return len(parts) == 3 && parts[0] != "did:" && parts[1] == "app.bsky.feed.post" && parts[2] != "" && !strings.ContainsAny(raw, "?# \t\r\n")
}

func safeMedia(raw any) bool {
	s, ok := raw.(string)
	if !ok || len(s) > 8192 || strings.ContainsAny(s, "\\\r\n\t") {
		return false
	}
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Hostname() != "" && u.User == nil && u.Fragment == ""
}

func matches(embed map[string]any, mode string, depth int) bool {
	if depth > 1 {
		return false
	}
	switch embed["$type"] {
	case "app.bsky.embed.recordWithMedia#view":
		media, _ := embed["media"].(map[string]any)
		return matches(media, mode, depth+1)
	case "app.bsky.embed.images#view":
		items, _ := embed["images"].([]any)
		return mode == "photos" && validImages(items, false)
	case "app.bsky.embed.gallery#view":
		items, _ := embed["items"].([]any)
		return mode == "photos" && validImages(items, true)
	case "app.bsky.embed.video#view":
		ratio, _ := embed["aspectRatio"].(map[string]any)
		width, _ := ratio["width"].(float64)
		height, _ := ratio["height"].(float64)
		return mode == "short-videos" && width > 0 && height > width && math.Trunc(width) == width && math.Trunc(height) == height && safeMedia(embed["playlist"]) && (embed["thumbnail"] == nil || safeMedia(embed["thumbnail"])) && embed["presentation"] != "gif"
	}
	return false
}

func validImages(items []any, gallery bool) bool {
	maximum := 4
	if gallery {
		maximum = 20
	}
	if len(items) == 0 || len(items) > maximum {
		return false
	}
	for _, raw := range items {
		item, ok := raw.(map[string]any)
		if !ok || gallery && item["$type"] != "app.bsky.embed.gallery#viewImage" {
			return false
		}
		thumb := item["thumb"]
		if gallery {
			thumb = item["thumbnail"]
		}
		if !safeMedia(thumb) || !safeMedia(item["fullsize"]) {
			return false
		}
	}
	return true
}
