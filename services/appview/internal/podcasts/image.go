package podcasts

import (
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

func (a *Assets) Image(w http.ResponseWriter, r *http.Request) {
	viewer, ok := assetViewer(w, r)
	if !ok {
		return
	}
	query := r.URL.Query()
	kind := query.Get("kind")
	if kind == "" {
		kind = "artwork"
	}
	index := 0
	var err error
	if raw, exists := query["index"]; exists {
		if len(raw) != 1 {
			assetError(w, 400, "Invalid image index")
			return
		}
		index, err = strconv.Atoi(raw[0])
	}
	if err != nil || index < 0 || index >= 1000 {
		assetError(w, 400, "Invalid image index")
		return
	}
	var target *string
	if id := query.Get("showId"); id != "" {
		if a.Show == nil {
			assetError(w, 404, "Image not found")
			return
		}
		show, e := a.Show(r.Context(), id, viewer)
		if assetStoreFailure(w, e) {
			return
		}
		if show == nil {
			assetError(w, 404, "Image not found")
			return
		}
		switch kind {
		case "artwork":
			target = show.ArtworkURL
		case "host":
			if index < len(show.Hosts) {
				target = show.Hosts[index].ImageURL
			}
		}
	} else if id := query.Get("episodeId"); id != "" && a.Episode != nil {
		episode, e := a.Episode(r.Context(), id, viewer)
		if assetStoreFailure(w, e) {
			return
		}
		if episode == nil {
			assetError(w, 404, "Image not found")
			return
		}
		switch kind {
		case "artwork":
			target = episode.ArtworkURL
		case "showArtwork":
			target = episode.ShowArtworkURL
		case "chapter":
			if index < len(episode.Chapters) {
				chapter := episode.Chapters[index]
				target = chapter.ArtworkURL
				if target != nil && strings.HasPrefix(*target, "/v1/podcasts/image?") {
					if a.Embedded == nil {
						assetError(w, 404, "Image not found")
						return
					}
					images, e := a.Embedded.Artwork(r.Context(), *episode, viewer, a.Fetcher)
					if e == nil {
						for _, image := range images {
							if math.Abs(image.StartSeconds-chapter.StartSeconds) < .5 {
								writePodcastImage(w, image.Data, image.MIMEType)
								return
							}
						}
					}
					assetError(w, 404, "Image not found")
					return
				}
			}
		}
	}
	if target == nil {
		assetError(w, 404, "Image not found")
		return
	}
	data, e := a.Fetcher.Fetch(r.Context(), *target, FetchOptions{MaximumBytes: 5 * 1024 * 1024})
	if e != nil {
		assetError(w, 502, "Podcast image could not be loaded")
		return
	}
	mime := podcastcore.ImageMIME(data)
	if mime == "" {
		assetError(w, 415, "Podcast image format is unsupported")
		return
	}
	writePodcastImage(w, data, mime)
}
func writePodcastImage(w http.ResponseWriter, data []byte, mime string) {
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(200)
	_, _ = w.Write(data)
}
