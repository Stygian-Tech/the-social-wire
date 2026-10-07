package podcasts

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func (s *Service) Hydrate(ctx context.Context, auth gatewaycore.AuthContext) ([]podcastcore.Show, error) {
	records := []podcastcore.Subscription{}
	cursor := ""
	seen := map[string]bool{}
	for {
		page, err := s.Repo.ListRecords(ctx, auth.DID, "app.skyreader.feed.subscription", cursor, 100, false)
		if err != nil {
			shows, err := s.Store.Shows(ctx, auth.DID)
			if err != nil {
				return nil, err
			}
			private, err := s.PrivateShows(ctx, auth.DID)
			return append(shows, private...), err
		}
		for _, item := range page.Records {
			values := recordValues(&item)
			feed, hasFeed := values["feedUrl"].(string)
			source, hasSource := values["externalRef"].(string)
			if hasFeed && !podcastcore.PublicRSSURLAllowed(feed) {
				continue
			}
			key := source
			hasKey := hasSource
			if hasFeed {
				if normalized := thinappviewcore.NormalizeFeedURL(feed); normalized != nil {
					key = *normalized
					hasKey = true
				}
			}
			if !hasKey {
				continue
			}
			show, err := s.Store.Show(ctx, key)
			if err != nil {
				return nil, err
			}
			if show == nil {
				if resolved, err := s.Resolve(ctx, key); err == nil {
					show = &resolved.Show
				}
			}
			if show == nil {
				continue
			}
			if show.SourceKind == "rss" && show.FeedURL != nil && !podcastcore.PublicRSSURLAllowed(*show.FeedURL) {
				continue
			}
			records = append(records, podcastcore.Subscription{ShowID: show.ID, URI: item.URI})
			if s.BridgeEnabled && show.SourceKind == "rss" && show.FeedURL != nil {
				payload, err := json.Marshal(map[string]string{"showId": show.ID, "feedUrl": *show.FeedURL})
				if err != nil {
					return nil, err
				}
				if _, err := s.Store.Enqueue(ctx, nil, nil, "bridge", "bridge:"+show.ID, string(payload)); err != nil {
					return nil, err
				}
			}
		}
		if page.Cursor == "" {
			break
		}
		if seen[page.Cursor] {
			return nil, ErrSourceUnavailable
		}
		seen[page.Cursor] = true
		cursor = page.Cursor
	}
	if err := s.Store.Subscriptions(ctx, auth.DID, records); err != nil {
		return nil, err
	}
	shows, err := s.Store.Shows(ctx, auth.DID)
	if err != nil {
		return nil, err
	}
	if s.BridgeEnabled {
		for i := range shows {
			raw, err := s.Store.Job(ctx, podcastcore.JobQuery{Viewer: auth.DID, Kind: pointer("bridge"), ShowID: &shows[i].ID})
			if err != nil {
				return nil, err
			}
			if raw != nil {
				var status map[string]any
				if err := json.Unmarshal([]byte(*raw), &status); err != nil {
					return nil, err
				}
				if id, ok := status["id"].(string); ok {
					shows[i].BridgeJobID = &id
				}
				if value, ok := status["status"].(string); ok {
					shows[i].BridgeStatus = &value
				}
			}
		}
	}
	private, err := s.PrivateShows(ctx, auth.DID)
	return append(shows, private...), err
}
func (s *Service) CanonicalState(ctx context.Context, state podcastcore.ListenerState) (podcastcore.ListenerState, error) {
	state.NormalizePlaybackSpeed()
	ids := append([]string{}, state.Queue...)
	for id := range state.Progress {
		ids = append(ids, id)
	}
	aliases, err := s.Store.CanonicalEpisodeIDs(ctx, ids)
	if err != nil {
		return state, err
	}
	manual, err := s.Store.ManualEpisodeAliases(ctx, state.ManualLinks)
	if err != nil {
		return state, err
	}
	for source, target := range manual {
		aliases[source] = target
	}
	queue, seen := []string{}, map[string]bool{}
	for _, id := range state.Queue {
		if canonical, ok := aliases[id]; ok {
			id = canonical
		}
		if !seen[id] {
			queue = append(queue, id)
			seen[id] = true
		}
	}
	state.Queue = queue
	progress := map[string]podcastcore.Progress{}
	for id, value := range state.Progress {
		progress[id] = value
	}
	state.Progress = progress
	for source, target := range aliases {
		if value, ok := state.Progress[source]; ok {
			delete(state.Progress, source)
			if existing, ok := state.Progress[target]; ok && progressDate(existing.UpdatedAt).After(progressDate(value.UpdatedAt)) {
				continue
			}
			state.Progress[target] = value
		}
	}
	return state, nil
}
func progressDate(raw string) time.Time { t, _ := time.Parse(time.RFC3339Nano, raw); return t }
func (s *Service) Transcripts(ctx context.Context, episode podcastcore.Episode) ([]podcastcore.Transcript, error) {
	result := append([]podcastcore.Transcript{}, episode.Transcripts...)
	for i := range result {
		t := &result[i]
		data, err := s.Fetcher.Fetch(ctx, t.URL, FetchOptions{MaximumBytes: 8 * 1024 * 1024})
		cues := []podcastcore.TranscriptCue{}
		if err == nil {
			plain, parsed := podcastcore.ParseTranscript(data, t.Type)
			t.Text = &plain
			cues = parsed
		}
		t.Cues = &cues
	}
	return result, nil
}
func (s *Service) Fingerprint(ctx context.Context, episode podcastcore.Episode) (string, error) {
	headers, _ := s.Fetcher.Fingerprint(ctx, episode.AudioURL)
	if headers != nil {
		return podcastcore.Identity(*headers), nil
	}
	encoded, err := swiftJSON(episode)
	if err != nil {
		return "", err
	}
	return podcastcore.Identity(encoded + "|" + strconv.FormatInt(s.now().Unix()/900, 10)), nil
}

// Sorted keys and slash escaping retain the durable Swift media fingerprint fallback.
func swiftJSON(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		return "", err
	}
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(swiftNumbers(generic)); err != nil {
		return "", err
	}
	return strings.ReplaceAll(swiftSeparators(strings.TrimSuffix(buf.String(), "\n")), "/", `\/`), nil
}

// Episode numeric fields are Swift Doubles. JSONEncoder uses scientific notation
// below 1e-4 and at 1e16, unlike Go's JSON number formatting thresholds.
func swiftNumbers(value any) any {
	switch v := value.(type) {
	case json.Number:
		f, err := v.Float64()
		if err != nil {
			return v
		}
		format := byte('f')
		magnitude := math.Abs(f)
		if magnitude != 0 && (magnitude < 1e-4 || magnitude >= 1e16) {
			format = 'e'
		}
		return json.Number(strconv.FormatFloat(f, format, -1, 64))
	case []any:
		for i := range v {
			v[i] = swiftNumbers(v[i])
		}
	case map[string]any:
		for key, item := range v {
			v[key] = swiftNumbers(item)
		}
	}
	return value
}

// Only unescape real JSON separator escapes, preserving literal backslash-u text.
func swiftSeparators(raw string) string {
	var out strings.Builder
	for i := 0; i < len(raw); i++ {
		if raw[i] == '\\' && i+1 < len(raw) {
			if strings.HasPrefix(raw[i:], `\u2028`) {
				out.WriteRune('\u2028')
				i += 5
				continue
			}
			if strings.HasPrefix(raw[i:], `\u2029`) {
				out.WriteRune('\u2029')
				i += 5
				continue
			}
			out.WriteByte(raw[i])
			i++
			out.WriteByte(raw[i])
			continue
		}
		out.WriteByte(raw[i])
	}
	return out.String()
}
