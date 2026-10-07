package podcastcore

import (
	"bytes"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"
)

var ErrInvalidXML = errors.New("invalid podcast XML")

type rssItem struct {
	fields      map[string]string
	transcripts []Transcript
	chapters    []Chapter
}

func xmlName(n xml.Name) string {
	if n.Space != "" {
		return strings.ToLower(n.Space + ":" + n.Local)
	}
	return strings.ToLower(n.Local)
}
func ParseRSS(data []byte, feedURL string) (Show, []Episode, error) {
	decoder := xml.NewDecoder(bytes.NewReader(data))
	stack, texts := []string{}, []string{}
	showFields := map[string]string{}
	items := []rssItem{}
	hosts := []Person{}
	item := rssItem{}
	inItem, sawRoot, closedRoot := false, false, false
	personAttributes := map[string]string{}
	for {
		token, err := decoder.RawToken()
		if err == io.EOF {
			break
		}
		if err != nil {
			return Show{}, nil, ErrInvalidXML
		}
		switch t := token.(type) {
		case xml.StartElement:
			key := xmlName(t.Name)
			if len(stack) == 0 {
				if sawRoot {
					return Show{}, nil, ErrInvalidXML
				}
				sawRoot = true
			}
			parent := ""
			if len(stack) > 0 {
				parent = stack[len(stack)-1]
			}
			stack = append(stack, key)
			texts = append(texts, "")
			a := map[string]string{}
			for _, attr := range t.Attr {
				a[xmlName(attr.Name)] = attr.Value
			}
			if key == "item" || key == "entry" {
				inItem = true
				item = rssItem{fields: map[string]string{}, transcripts: []Transcript{}, chapters: []Chapter{}}
			}
			if key == "enclosure" || key == "link" && a["rel"] == "enclosure" {
				audio := a["url"]
				if audio == "" {
					audio = a["href"]
				}
				var mime *string
				if s, ok := a["type"]; ok {
					mime = &s
				}
				if audio != "" && IsAudio(audio, mime) && item.fields != nil {
					if _, ok := item.fields["audio"]; !ok {
						item.fields["audio"] = audio
						if mime != nil {
							item.fields["audioType"] = *mime
						}
					}
				}
			}
			if key == "podcast:person" && !inItem && parent == "channel" {
				personAttributes = a
			}
			if key == "podcast:chapters" && inItem {
				if s := safeURL(mapValue(a, "url")); s != nil {
					item.fields["chapterSourceUrl"] = *s
				}
			}
			if key == "psc:chapter" && inItem && len(item.chapters) < 1000 {
				start := ParseDuration(mapValue(a, "start"))
				title, ok := a["title"]
				if start != nil && ok {
					item.chapters = append(item.chapters, Chapter{StartSeconds: *start, Title: prefix(title, 512), ArtworkURL: safeURL(mapValue(a, "image")), URL: safeURL(mapValue(a, "href"))})
				}
			}
			if key == "itunes:image" {
				if href, ok := a["href"]; ok {
					if inItem {
						item.fields["artwork"] = href
					} else {
						showFields["artwork"] = href
					}
				}
			}
			if key == "podcast:transcript" && inItem {
				if u, ok := a["url"]; ok {
					mime := "text/plain"
					if v, ok := a["type"]; ok {
						mime = v
					}
					item.transcripts = append(item.transcripts, Transcript{URL: u, Type: mime, Language: mapValue(a, "language")})
				}
			}
		case xml.CharData:
			if len(texts) > 0 {
				texts[len(texts)-1] += string(t)
			} else if strings.TrimSpace(string(t)) != "" {
				return Show{}, nil, ErrInvalidXML
			}
		case xml.EndElement:
			key := xmlName(t.Name)
			n := len(stack)
			if n == 0 || stack[n-1] != key {
				return Show{}, nil, ErrInvalidXML
			}
			text := texts[n-1]
			stack = stack[:n-1]
			texts = texts[:n-1]
			if len(stack) == 0 {
				closedRoot = true
			} else {
				texts[len(texts)-1] += text
			}
			clean := strings.TrimSpace(text)
			parent := ""
			if len(stack) > 0 {
				parent = stack[len(stack)-1]
			}
			if key == "item" || key == "entry" {
				sort.SliceStable(item.chapters, func(i, j int) bool { return item.chapters[i].StartSeconds < item.chapters[j].StartSeconds })
				items = append(items, item)
				inItem = false
				continue
			}
			if key == "podcast:person" && !inItem && parent == "channel" && len(hosts) < 100 {
				role := "host"
				if s, ok := personAttributes["role"]; ok {
					role = s
				}
				hosts = append(hosts, PeopleRows([]any{map[string]any{"name": clean, "role": role, "img": personAttributes["img"], "href": personAttributes["href"]}})...)
				personAttributes = map[string]string{}
			}
			if inItem {
				if clean != "" {
					item.fields[key] = clean
				}
			} else if clean != "" && parent == "channel" && (key == "title" || key == "description" || key == "podcast:guid") {
				showFields[key] = clean
			} else if key == "url" && parent == "image" {
				showFields["artwork"] = clean
			}
		}
	}
	if !sawRoot || !closedRoot || len(stack) != 0 || inItem {
		return Show{}, nil, ErrInvalidXML
	}
	identity := feedURL
	if s, ok := showFields["podcast:guid"]; ok {
		identity = s
	}
	title := "Untitled Podcast"
	if s, ok := showFields["title"]; ok {
		title = s
	}
	show := Show{ID: "podcast:" + Identity(identity), Title: title, Description: mapValue(showFields, "description"), ArtworkURL: mapValue(showFields, "artwork"), FeedURL: pointer(feedURL), SourceKind: "rss", Guid: mapValue(showFields, "podcast:guid"), Hosts: hosts}
	episodes := []Episode{}
	for _, item := range items {
		f := item.fields
		audio, ok := f["audio"]
		if !ok || !IsAudio(audio, mapValue(f, "audioType")) {
			continue
		}
		u, err := url.Parse(audio)
		if err != nil || (strings.ToLower(u.Scheme) != "https" && strings.ToLower(u.Scheme) != "http") {
			continue
		}
		guid := audio
		if s, ok := f["guid"]; ok {
			guid = s
		} else if s, ok := f["id"]; ok {
			guid = s
		}
		title := "Untitled Episode"
		if s, ok := f["title"]; ok {
			title = s
		}
		description := mapValue(f, "description")
		if description == nil {
			description = mapValue(f, "summary")
		}
		art := mapValue(f, "artwork")
		if art == nil {
			art = show.ArtworkURL
		}
		published := mapValue(f, "pubdate")
		if published == nil {
			published = mapValue(f, "published")
		}
		episodes = append(episodes, Episode{ID: "episode:" + Identity(show.ID+"|"+guid), ShowID: show.ID, Title: title, Description: description, PublishedAt: rssDate(published), AudioURL: audio, AudioMimeType: mapValue(f, "audioType"), DurationSeconds: ParseDuration(mapValue(f, "itunes:duration")), ArtworkURL: art, Guid: pointer(guid), Transcripts: item.transcripts, Chapters: item.chapters, ChapterSourceURL: mapValue(f, "chapterSourceUrl"), ShowArtworkURL: show.ArtworkURL})
	}
	return show, episodes, nil
}
func mapValue(m map[string]string, key string) *string {
	s, ok := m[key]
	if !ok {
		return nil
	}
	return &s
}
func IsAudio(raw string, mime *string) bool {
	if mime != nil {
		return strings.HasPrefix(strings.ToLower(*mime), "audio/")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	switch strings.ToLower(strings.TrimPrefix(path.Ext(u.Path), ".")) {
	case "mp3", "m4a", "aac", "ogg", "opus", "wav", "flac":
		return true
	}
	return false
}
func ParseDuration(raw *string) *float64 {
	if raw == nil {
		return nil
	}
	result := 0.0
	for _, part := range strings.Split(*raw, ":") {
		if part == "" {
			continue
		}
		n, err := strconv.ParseFloat(part, 64)
		if err != nil || n < 0 || math.IsNaN(n) || math.IsInf(n, 0) {
			return nil
		}
		result = result*60 + n
	}
	return &result
}
func rssDate(raw *string) string {
	if raw != nil {
		if _, err := time.Parse(time.RFC3339, *raw); err == nil && !strings.Contains(*raw, ".") {
			return *raw
		}
		for _, layout := range []string{time.RFC1123Z, "Mon, 2 Jan 2006 15:04:05 -0700", time.RFC1123} {
			if t, err := time.Parse(layout, *raw); err == nil {
				return t.UTC().Format(time.RFC3339)
			}
		}
	}
	return "1970-01-01T00:00:00Z"
}
