package gateway

import (
	"context"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

const socialDraftGIFPath = "/xrpc/app.thesocialwire.socialDraft.getGifFile"

// GIF files are resolved from the server-owned catalog, never from a caller URL.
// Spooling validates the entire bounded response before releasing private bytes
// and avoids allocating a 100 MiB buffer for each admitted transfer.
func (s *Server) socialDraftGIF(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || strings.TrimSpace(auth.DID) == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		writeError(w, 401, "Authentication required")
		return
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query) != 2 || len(query["id"]) != 1 || len(query["rendition"]) != 1 || !gifID.MatchString(query.Get("id")) {
		writeError(w, 400, "Invalid GIF file selector")
		return
	}
	rendition := query.Get("rendition")
	if rendition != "gif" && rendition != "poster" && rendition != "mp4" && rendition != "webm" {
		writeError(w, 400, "Invalid GIF file rendition")
		return
	}
	if s.Config.KlipyAPIKey == "" || s.Public == nil {
		writeError(w, 503, "GIF files unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), socialDraftUploadTimeout)
	defer cancel()
	controller := http.NewResponseController(w)
	_ = controller.SetWriteDeadline(time.Now().Add(socialDraftUploadTimeout))
	defer controller.SetWriteDeadline(time.Time{})
	assets, _, err := s.fetchGIFs(ctx, "posts", url.Values{"ids": {query.Get("id")}})
	if err != nil {
		writeError(w, 502, "GIF catalog unavailable")
		return
	}
	var asset *gifAsset
	for i := range assets {
		if assets[i].ID == query.Get("id") {
			asset = &assets[i]
			break
		}
	}
	if asset == nil {
		writeError(w, 404, "GIF file not found")
		return
	}
	raw := asset.URL
	switch rendition {
	case "poster":
		raw = asset.Poster
	case "mp4":
		raw = asset.MP4
	case "webm":
		raw = asset.WebM
	}
	// An unavailable format is never substituted by another rendition.
	if raw == "" {
		writeError(w, 404, "GIF rendition not found")
		return
	}
	u, err := url.Parse(raw)
	if err != nil || klipyMediaURL(raw) == "" || u.RawQuery != "" || u.ForceQuery || u.RawPath != "" || path.Clean(u.Path) != u.Path || u.Path == "/ii/" {
		writeError(w, 502, "GIF file unavailable")
		return
	}
	req, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		writeError(w, 502, "GIF file unavailable")
		return
	}
	req.Header.Set("Accept-Encoding", "identity")
	client := *s.Public // Retain the public client's pinned-DNS/SSRF transport.
	client.Timeout = socialDraftUploadTimeout
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := client.Do(req)
	if err != nil {
		writeError(w, 502, "GIF file unavailable")
		return
	}
	defer resp.Body.Close()
	media, _, err := mime.ParseMediaType(resp.Header.Get("Content-Type"))
	if resp.StatusCode != 200 || err != nil || !gifFileMIME(rendition, media) || (resp.Header.Get("Content-Encoding") != "" && resp.Header.Get("Content-Encoding") != "identity") {
		writeError(w, 502, "Invalid GIF file response")
		return
	}
	limit := int64(100 << 20)
	if rendition == "poster" {
		limit = 1_000_000
	}
	if resp.ContentLength > limit {
		writeError(w, 413, "GIF file exceeds size limit")
		return
	}
	file, err := os.CreateTemp("", "social-draft-gif-*")
	if err != nil {
		writeError(w, 503, "GIF files unavailable")
		return
	}
	defer func() { file.Close(); os.Remove(file.Name()) }()
	length, err := io.Copy(file, io.LimitReader(resp.Body, limit+1))
	if length > limit {
		writeError(w, 413, "GIF file exceeds size limit")
		return
	}
	if err != nil || length == 0 || (resp.ContentLength >= 0 && resp.ContentLength != length) {
		writeError(w, 502, "Invalid GIF file response")
		return
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		writeError(w, 503, "GIF files unavailable")
		return
	}
	var head [512]byte
	n, err := file.Read(head[:])
	if (err != nil && err != io.EOF) || http.DetectContentType(head[:n]) != media {
		writeError(w, 502, "Invalid GIF file bytes")
		return
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		writeError(w, 503, "GIF files unavailable")
		return
	}
	w.Header().Set("Content-Type", media)
	w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
	w.WriteHeader(200)
	if _, err = io.Copy(w, file); err != nil {
		panic(http.ErrAbortHandler)
	}
}

func gifFileMIME(rendition, media string) bool {
	switch rendition {
	case "gif":
		return media == "image/gif"
	case "mp4":
		return media == "video/mp4"
	case "webm":
		return media == "video/webm"
	case "poster":
		return media == "image/jpeg" || media == "image/png" || media == "image/webp"
	}
	return false
}
