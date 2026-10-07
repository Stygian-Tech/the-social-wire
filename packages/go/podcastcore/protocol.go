package podcastcore

import (
	"errors"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

var ErrUnsupportedSource = errors.New("unsupported podcast source")
var ProtocolCollections = map[string]string{"org.atpodcasting.podcast": "org.atpodcasting.episode", "place.pod.show": "place.pod.episode", "live.voxport.podcast.series": "live.voxport.podcast.episode"}

func parseATURI(uri string) (did, collection string, ok bool) {
	if !strings.HasPrefix(uri, "at://") {
		return "", "", false
	}
	parts := strings.Split(strings.TrimPrefix(uri, "at://"), "/")
	if len(parts) != 3 || parts[0] == "" || parts[1] == "" || parts[2] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}
func ProtocolShow(uri string, record map[string]any, blobBase string) (Show, error) {
	did, collection, ok := parseATURI(uri)
	title := rowString(record, "title")
	episodeCollection := ProtocolCollections[collection]
	if !ok || title == nil || episodeCollection == "" {
		return Show{}, ErrUnsupportedSource
	}
	artwork := rowString(record, "imageUrl", "artworkUrl", "coverImageUrl")
	if artwork == nil {
		for _, key := range []string{"artwork", "cover", "image"} {
			cid := thinappviewcore.ExtractBlobLink(record[key])
			if cid != "" {
				if u := thinappviewcore.BuildSyncGetBlobURL(blobBase, did, cid); u != "" {
					artwork = &u
					break
				}
			}
		}
	}
	return Show{ID: uri, Title: *title, Description: rowString(record, "description", "summary"), ArtworkURL: artwork, FeedURL: rowString(record, "feedUrl", "rssFeedUrl"), SourceKind: "atproto", SourceURI: &uri, Guid: rowString(record, "podcastGuid", "guid"), EpisodeCollection: &episodeCollection, Hosts: PeopleRows(rowArray(record, "hosts", "persons", "people"))}, nil
}
func ProtocolEpisode(uri string, record map[string]any, show Show, blobBase string) *Episode {
	did, collection, ok := parseATURI(uri)
	if !ok || show.SourceURI == nil {
		return nil
	}
	_, showCollection, ok := parseATURI(*show.SourceURI)
	if !ok || ProtocolCollections[showCollection] != collection {
		return nil
	}
	reference := rowString(record, "showUri")
	if reference == nil {
		reference = rowString(rowObject(record, "series"), "uri")
	}
	if collection == "org.atpodcasting.episode" {
		guid := rowString(rowObject(record, "podcast"), "podcastGuid")
		if show.Guid == nil || guid == nil || *show.Guid != *guid {
			return nil
		}
	} else if reference == nil || *reference != *show.SourceURI {
		return nil
	}
	media, blob := rowObject(record, "media"), rowObject(record, "audio")
	audio := valueString(firstValue(media["url"], record["audioUrl"]))
	if audio == nil {
		if cid := thinappviewcore.ExtractBlobLink(blob); cid != "" {
			if u := thinappviewcore.BuildSyncGetBlobURL(blobBase, did, cid); u != "" {
				audio = &u
			}
		}
	}
	mime := valueString(firstValue(media["mimeType"], record["audioMimeType"], record["audioType"], blob["mimeType"]))
	title, published := rowString(record, "title"), rowString(record, "publishedAt")
	if audio == nil || !IsAudio(*audio, mime) || title == nil || published == nil {
		return nil
	}
	transcripts := []Transcript{}
	refs := rowArray(record, "transcripts", "transcript")
	if len(refs) == 0 {
		if singular := rowObject(record, "transcript"); singular != nil {
			refs = []any{singular}
		}
	}
	for _, v := range refs {
		item, ok := v.(map[string]any)
		if !ok {
			continue
		}
		u := rowString(item, "url")
		if u == nil {
			continue
		}
		mime := "text/plain"
		if s := rowString(item, "type", "mimeType"); s != nil {
			mime = *s
		}
		transcripts = append(transcripts, Transcript{URL: *u, Type: mime, Language: rowString(item, "language")})
	}
	if u := rowString(record, "transcriptUrl"); u != nil {
		mime := "text/plain"
		if s := rowString(record, "transcriptMimeType"); s != nil {
			mime = *s
		}
		transcripts = append(transcripts, Transcript{URL: *u, Type: mime})
	}
	artwork := rowString(record, "imageUrl")
	if artwork == nil {
		artwork = show.ArtworkURL
	}
	duration := rowNumber(record, "durationSeconds", "duration")
	chapterSource := rowString(record, "chaptersUrl")
	if _, exists := record["chaptersUrl"]; !exists {
		chapterSource = rowString(rowObject(record, "chapters"), "url")
	}
	return &Episode{ID: uri, ShowID: show.ID, Title: *title, Description: rowString(record, "description", "summary"), PublishedAt: *published, AudioURL: *audio, AudioMimeType: mime, DurationSeconds: duration, ArtworkURL: artwork, Guid: rowString(record, "feedItemGuid", "guid", "importedGuid"), SourceURI: &uri, Transcripts: transcripts, Chapters: ChapterRows(rowArray(record, "chapters"), duration), ChapterSourceURL: safeURL(chapterSource), ShowArtworkURL: show.ArtworkURL}
}
func rowObject(row map[string]any, key string) map[string]any {
	v, _ := row[key].(map[string]any)
	return v
}
func rowArray(row map[string]any, keys ...string) []any {
	for _, key := range keys {
		if v, ok := row[key]; ok {
			rows, _ := v.([]any)
			return rows
		}
	}
	return nil
}
func firstValue(values ...any) any {
	for _, v := range values {
		if v != nil {
			return v
		}
	}
	return nil
}
func valueString(value any) *string {
	if s, ok := value.(string); ok {
		return &s
	}
	return nil
}
