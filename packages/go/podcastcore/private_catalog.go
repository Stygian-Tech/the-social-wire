package podcastcore

import (
	"crypto/sha256"
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

func Identity(value string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(value))) }
func IsPrivateID(id string) bool   { return strings.HasPrefix(id, "private-podcast:") }
func PrivateURLAllowed(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && strings.EqualFold(u.Scheme, "https") && u.Hostname() != "" && u.User == nil
}
func PublicRSSURLAllowed(raw string) bool {
	raw = strings.TrimSpace(raw)
	if !PrivateURLAllowed(raw) {
		return false
	}
	u, _ := url.Parse(raw)
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return false
	}
	for key, values := range query {
		key = strings.ToLower(key)
		if key != "feed" && key != "format" {
			return false
		}
		for _, v := range values {
			switch strings.ToLower(v) {
			case "rss", "rss2", "atom", "rdf", "xml":
			default:
				return false
			}
		}
	}
	return true
}
func ScopePrivate(viewer, feedURL string, show Show, episodes []Episode) (Show, []Episode) {
	show.ID = "private-podcast:show:" + Identity(viewer+"|"+feedURL)
	show.SourceKind = "private-rss"
	show.Visibility = pointer("private")
	show.SourceURI = nil
	show.BridgeJobID = nil
	show.BridgeStatus = nil
	result := append([]Episode{}, episodes...)
	for i := range result {
		e := &result[i]
		guid := e.ID
		if e.Guid != nil {
			guid = *e.Guid
		}
		e.ID = "private-podcast:episode:" + Identity(show.ID+"|"+guid)
		e.ShowID = show.ID
		e.SourceURI = nil
		e.Visibility = pointer("private")
	}
	return show, result
}

var privateLinkPattern = regexp.MustCompile(`(?i)https?://[^\s<>"']+`)

func VisibleText(s string) string { return privateLinkPattern.ReplaceAllString(s, "[Private Link]") }
func ImageURL(showID, episodeID, kind string, index int) string {
	owner := "episodeId=" + episodeID
	if showID != "" {
		owner = "showId=" + showID
	}
	return fmt.Sprintf("/v1/podcasts/image?%s&kind=%s&index=%d", owner, kind, index)
}
func VisibleShow(s Show) Show {
	s.Title = VisibleText(s.Title)
	s.Description = mapText(s.Description)
	s.FeedURL = nil
	s.SourceURI = nil
	s.Guid = nil
	s.EpisodeCollection = nil
	s.BridgeJobID = nil
	s.BridgeStatus = nil
	if s.ArtworkURL != nil {
		s.ArtworkURL = pointer(ImageURL(s.ID, "", "artwork", 0))
	}
	s.Hosts = append([]Person{}, s.Hosts...)
	for i := range s.Hosts {
		p := &s.Hosts[i]
		p.Name = VisibleText(p.Name)
		p.URL = nil
		if p.ImageURL != nil {
			p.ImageURL = pointer(ImageURL(s.ID, "", "host", i))
		}
	}
	return s
}
func VisibleEpisode(e Episode) Episode {
	e.Title = VisibleText(e.Title)
	e.Description = mapText(e.Description)
	e.AudioURL = "/v1/podcasts/media?episodeId=" + e.ID
	if e.ArtworkURL != nil {
		e.ArtworkURL = pointer(ImageURL("", e.ID, "artwork", 0))
	}
	if e.ShowArtworkURL != nil {
		e.ShowArtworkURL = pointer(ImageURL("", e.ID, "showArtwork", 0))
	}
	e.ChapterSourceURL = nil
	e.SourceURI = nil
	e.Guid = nil
	e.Chapters = append([]Chapter{}, e.Chapters...)
	for i := range e.Chapters {
		c := &e.Chapters[i]
		c.Title = VisibleText(c.Title)
		c.URL = nil
		if c.ArtworkURL != nil {
			c.ArtworkURL = pointer(ImageURL("", e.ID, "chapter", i))
		}
	}
	e.Transcripts = append([]Transcript{}, e.Transcripts...)
	for i := range e.Transcripts {
		e.Transcripts[i].URL = ""
	}
	return e
}
func pointer[T any](v T) *T { return &v }
func mapText(s *string) *string {
	if s == nil {
		return nil
	}
	return pointer(VisibleText(*s))
}
