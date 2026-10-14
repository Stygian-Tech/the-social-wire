package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// This adapter uses KLIPY's documented Tenor-compatible v2 API.
// Provider credentials and raw provider responses never cross the Gateway edge.
type gifRendition struct {
	URL  string `json:"url"`
	Dims []int  `json:"dims"`
}
type providerGIF struct {
	ID          string                  `json:"id"`
	Title       string                  `json:"title"`
	Description string                  `json:"content_description"`
	Formats     map[string]gifRendition `json:"media_formats"`
}
type gifAsset struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	URL         string `json:"url"`
	Poster      string `json:"poster"`
	MP4         string `json:"mp4,omitempty"`
	WebM        string `json:"webm,omitempty"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
	Attribution string `json:"attribution"`
}

var gifID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func klipyMediaURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host != "static.klipy.com" || u.User != nil || !strings.HasPrefix(u.Path, "/ii/") || u.Fragment != "" {
		return ""
	}
	return u.String()
}

func normalizeGIF(g providerGIF) (gifAsset, bool) {
	full, preview := g.Formats["gif"], g.Formats["preview"]
	if !gifID.MatchString(g.ID) || len(full.Dims) != 2 || full.Dims[0] <= 0 || full.Dims[1] <= 0 || full.Dims[0] > 20000 || full.Dims[1] > 20000 {
		return gifAsset{}, false
	}
	a := gifAsset{ID: g.ID, Title: g.Title, Description: g.Description, URL: klipyMediaURL(full.URL), Poster: klipyMediaURL(preview.URL), MP4: klipyMediaURL(g.Formats["mp4"].URL), WebM: klipyMediaURL(g.Formats["webm"].URL), Width: full.Dims[0], Height: full.Dims[1], Attribution: "Powered by KLIPY"}
	if a.URL == "" || a.Poster == "" || (a.MP4 == "" && a.WebM == "") {
		return gifAsset{}, false
	}
	// Bluesky encodes video filename slugs alongside the GIF URI. Only accept
	// renditions in that same directory so other clients can reconstruct them.
	base, _ := url.Parse(a.URL)
	dir := base.Path[:strings.LastIndex(base.Path, "/")+1]
	for _, raw := range []string{a.MP4, a.WebM} {
		if raw != "" {
			u, _ := url.Parse(raw)
			if !strings.HasPrefix(u.Path, dir) || strings.Contains(strings.TrimPrefix(u.Path, dir), "/") {
				return gifAsset{}, false
			}
		}
	}
	return a, true
}

func (s *Server) fetchGIFs(ctx context.Context, endpoint string, params url.Values) ([]gifAsset, string, error) {
	params.Set("key", s.Config.KlipyAPIKey)
	params.Set("client_key", "social-wire")
	params.Set("contentfilter", "medium")
	params.Set("limit", "24")
	r, err := http.NewRequestWithContext(ctx, "GET", "https://api.klipy.com/v2/"+endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return nil, "", err
	}
	client := *s.Public
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(r)
	if err != nil {
		return nil, "", fmt.Errorf("GIF service unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode == 429 {
		return nil, "", fmt.Errorf("GIF service rate limited")
	}
	if resp.StatusCode != 200 {
		return nil, "", fmt.Errorf("GIF service unavailable")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 2_000_001))
	if err != nil || len(body) > 2_000_000 {
		return nil, "", fmt.Errorf("invalid GIF response")
	}
	var result struct {
		Results []providerGIF `json:"results"`
		Next    string        `json:"next"`
	}
	if json.Unmarshal(body, &result) != nil || len(result.Results) > 100 || len(result.Next) > 512 {
		return nil, "", fmt.Errorf("invalid GIF response")
	}
	assets := make([]gifAsset, 0, len(result.Results))
	for _, g := range result.Results {
		if a, ok := normalizeGIF(g); ok {
			assets = append(assets, a)
		}
	}
	return assets, result.Next, nil
}

func (s *Server) gifs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.Config.KlipyAPIKey == "" {
		writeError(w, 503, "GIF Search Is Not Configured")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	q := r.URL.Query()
	id, query, cursor := q.Get("id"), strings.TrimSpace(q.Get("q")), q.Get("cursor")
	if len(query) > 200 || len(cursor) > 512 || (id != "" && !gifID.MatchString(id)) {
		writeError(w, 400, "Invalid GIF Query")
		return
	}
	endpoint, params := "featured", url.Values{}
	if query != "" {
		endpoint = "search"
		params.Set("q", query)
	}
	if cursor != "" {
		params.Set("pos", cursor)
	}
	if id != "" {
		endpoint = "posts"
		params = url.Values{"ids": {id}}
	}
	assets, next, err := s.fetchGIFs(ctx, endpoint, params)
	if err != nil {
		if err.Error() == "GIF service rate limited" {
			writeError(w, 429, "GIF Search Rate Limited. Try Again Shortly.")
			return
		}
		writeError(w, 502, err.Error())
		return
	}
	if id != "" {
		filtered := assets[:0]
		for _, a := range assets {
			if a.ID == id {
				filtered = append(filtered, a)
			}
		}
		assets = filtered
		if len(assets) == 0 {
			writeError(w, 404, "This GIF Is No Longer Available")
			return
		}
	}
	if r.URL.Path == "/v1/media/gifs/thumbnail" {
		if id == "" {
			writeError(w, 400, "GIF ID Required")
			return
		}
		req, _ := http.NewRequestWithContext(ctx, "GET", assets[0].Poster, nil)
		client := *s.Public
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
		resp, e := client.Do(req)
		if e != nil {
			writeError(w, 502, "GIF Preview Unavailable")
			return
		}
		defer resp.Body.Close()
		mime := strings.Split(resp.Header.Get("Content-Type"), ";")[0]
		if resp.StatusCode != 200 || (mime != "image/jpeg" && mime != "image/png" && mime != "image/webp") {
			writeError(w, 502, "GIF Preview Unavailable")
			return
		}
		body, e := io.ReadAll(io.LimitReader(resp.Body, 1_000_001))
		if e != nil || len(body) == 0 || len(body) > 1_000_000 {
			writeError(w, 502, "GIF Preview Exceeds Size Limit")
			return
		}
		w.Header().Set("Content-Type", mime)
		w.Write(body)
		return
	}
	writeJSON(w, 200, map[string]any{"results": assets, "next": next})
}
