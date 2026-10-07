package edge

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type Handler struct {
	Store  corpuscore.Store
	Config Config
	Replay *ReplayGuard
	Now    func() time.Time
}

func NewHandler(store corpuscore.Store, config Config) *Handler {
	return &Handler{Store: store, Config: config, Replay: NewReplayGuard(10000), Now: time.Now}
}

var identifierPattern = regexp.MustCompile(`^[a-zA-Z0-9:_-]+$`)
var uuidPattern = regexp.MustCompile(`^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$`)
var actorPattern = regexp.MustCompile(`^h1:[a-f0-9]{64}$`)

func (c *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	now := c.Now()
	ctx := r.Context()
	path := r.URL.Path
	if r.Method == "GET" && (path == "/health" || path == "/livez" || path == "/readyz") {
		status := "live"
		if path == "/readyz" {
			if err := c.Store.Ping(ctx); err != nil {
				respondError(w, err)
				return
			}
			if err := c.Store.RequireFreshBaseline(ctx, now); err != nil {
				respondError(w, err)
				return
			}
			status = "ready"
		}
		writeJSON(w, 200, map[string]string{"service": "wire-corpus-edge", "status": status}, false)
		return
	}
	if !strings.HasPrefix(path, "/internal/wire/v1/") {
		respondStatus(w, 404)
		return
	}
	if !c.authenticate(r, now) {
		respondStatus(w, 401)
		return
	}
	operation := strings.TrimPrefix(path, "/internal/wire/v1/")
	if r.Method != "GET" && !(r.Method == "POST" && operation == "circle-candidates") {
		respondStatus(w, 404)
		return
	}
	allowed := map[string][]string{
		"contract": {}, "finance": {"language"}, "sports": {"language"}, "sports/schedules": {}, "sports/standings": {"preferredIDs"},
		"sports/events": {"competitionIDs", "entityIDs", "global", "teamIDs", "preferredIDs", "timeZone"},
		"feed":          {"generationId", "language", "limit", "startOrdinal", "fallbackLimit"}, "edition": {"language", "region", "fallbackLimit"}, "item": {"itemId"}, "catalog": {}, "circle-candidates": {},
	}
	names, exists := allowed[operation]
	if !exists {
		respondStatus(w, 404)
		return
	}
	query, err := parseQuery(r.URL.RawQuery, names)
	if err != nil {
		respondStatus(w, 400)
		return
	}
	var result any
	switch operation {
	case "contract":
		err = c.Store.Ping(ctx)
		result = map[string]int{"contractVersion": 3}
	case "finance":
		if err = c.Store.RequireFreshBaseline(ctx, now); err == nil {
			result, err = c.Store.Finance(ctx, primaryLanguage(query["language"]), now)
		}
	case "sports":
		if err = c.Store.RequireFreshBaseline(ctx, now); err == nil {
			result, err = c.Store.Sports(ctx, primaryLanguage(query["language"]), now)
			if err == nil {
				value := result.(corpuscore.SportsGeneration)
				for _, candidate := range value.Candidates {
					if candidate.Analysis.ResolverVersion != sportscore.ResolverVersion {
						err = corpuscore.ErrUnavailable
						break
					}
					for _, association := range candidate.Analysis.Associations {
						if association.ResolverVersion != sportscore.ResolverVersion {
							err = corpuscore.ErrUnavailable
							break
						}
					}
				}
			}
		}
	case "sports/schedules":
		result, err = c.Store.SportsSchedules(ctx, now)
	case "sports/standings":
		var ids []string
		ids, err = identifiers(query, "preferredIDs", 100, 128, true)
		if err == nil {
			result, err = c.Store.SportsStandings(ctx, ids, now)
		}
	case "sports/events":
		var q corpuscore.EventsQuery
		q.Global = true
		if global, ok := query["global"]; ok {
			if global != "true" && global != "false" {
				respondStatus(w, 400)
				return
			}
			q.Global = global == "true"
		}
		for _, key := range []string{"competitionIDs", "entityIDs", "teamIDs", "preferredIDs"} {
			maximum, width, empty := 200, 256, false
			if key == "teamIDs" || key == "preferredIDs" {
				maximum, width, empty = 100, 128, true
			}
			ids, e := identifiers(query, key, maximum, width, empty)
			if e != nil {
				respondStatus(w, 400)
				return
			}
			switch key {
			case "competitionIDs":
				q.CompetitionIDs = ids
			case "entityIDs":
				q.EntityIDs = ids
			case "teamIDs":
				if _, present := query[key]; present {
					q.TeamIDs = ids
				}
			case "preferredIDs":
				q.PreferredIDs = ids
			}
		}
		zone, ok := query["timeZone"]
		if !ok {
			zone = "Etc/UTC"
		}
		if len(zone) > 128 || zone == "Local" || zone == "" {
			respondStatus(w, 400)
			return
		}
		q.TimeZone, err = time.LoadLocation(zone)
		if err == nil {
			result, err = c.Store.SportsEvents(ctx, q, now)
		} else {
			respondStatus(w, 400)
			return
		}
	case "feed":
		q := corpuscore.FeedQuery{Language: primaryLanguage(query["language"])}
		if id, ok := query["generationId"]; ok {
			if !uuidPattern.MatchString(id) {
				respondStatus(w, 400)
				return
			}
			id = strings.ToLower(id)
			q.GenerationID = &id
		}
		q.StartOrdinal, err = boundedInt(query, "startOrdinal", 0, 0, 10000000)
		if err != nil {
			respondStatus(w, 400)
			return
		}
		q.Limit, err = boundedInt(query, "limit", 500, 1, 500)
		if err != nil {
			respondStatus(w, 400)
			return
		}
		if _, ok := query["fallbackLimit"]; ok {
			value, e := boundedInt(query, "fallbackLimit", 500, 1, 5000)
			if e != nil {
				respondStatus(w, 400)
				return
			}
			q.FallbackLimit = &value
		}
		result, err = c.Store.Feed(ctx, q, now)
	case "edition":
		q := corpuscore.EditionQuery{Language: primaryLanguage(query["language"])}
		if region := query["region"]; region == "outside-us" {
			q.Region = &region
		}
		if _, ok := query["fallbackLimit"]; ok {
			value, e := boundedInt(query, "fallbackLimit", 50, 1, 5000)
			if e != nil {
				respondStatus(w, 400)
				return
			}
			q.FallbackLimit = &value
		}
		result, err = c.Store.Edition(ctx, q, now)
	case "item":
		id := query["itemId"]
		if len(id) == 0 || len(id) > 128 {
			respondStatus(w, 400)
			return
		}
		var item *corpuscore.Item
		item, err = c.Store.Item(ctx, id, now)
		if err == nil && item == nil {
			respondStatus(w, 404)
			return
		}
		result = item
	case "catalog":
		result, err = c.Store.Catalog(ctx, now)
	case "circle-candidates":
		if r.Method != "POST" {
			respondStatus(w, 404)
			return
		}
		body, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if e != nil {
			respondStatus(w, 413)
			return
		}
		if r.Header.Get(wirecore.CorpusBodyDigestHeader) != wirecore.CorpusBodyDigest(body) {
			respondStatus(w, 401)
			return
		}
		var input corpuscore.CandidateRequest
		var fields map[string]json.RawMessage
		if json.Unmarshal(body, &input) != nil || json.Unmarshal(body, &fields) != nil {
			respondStatus(w, 400)
			return
		}
		for _, key := range []string{"actorHashes", "language", "since", "limit"} {
			if data, ok := fields[key]; !ok || string(data) == "null" {
				respondStatus(w, 400)
				return
			}
		}
		seen := map[string]bool{}
		valid := len(input.ActorHashes) > 0 && len(input.ActorHashes) <= 5000 && input.Limit >= 1 && input.Limit <= 500 && !input.Since.After(now.Add(time.Minute)) && !input.Since.Before(now.Add(-7*24*time.Hour))
		for _, actor := range input.ActorHashes {
			if seen[actor] || !actorPattern.MatchString(actor) {
				valid = false
			}
			seen[actor] = true
		}
		if !valid {
			respondStatus(w, 400)
			return
		}
		input.Language = primaryLanguage(input.Language)
		result, err = c.Store.CircleCandidates(ctx, input, now)
	}
	if err != nil {
		respondError(w, err)
		return
	}
	writeJSON(w, 200, result, true)
}
func primaryLanguage(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	value := strings.Split(raw, "-")[0]
	if len(value) < 2 || len(value) > 8 {
		return "und"
	}
	for _, ch := range value {
		if ch < 'a' || ch > 'z' {
			return "und"
		}
	}
	return value
}
func parseQuery(raw string, allowed []string) (map[string]string, error) {
	values := map[string]string{}
	if raw == "" {
		return values, nil
	}
	allow := map[string]bool{}
	for _, name := range allowed {
		allow[name] = true
	}
	for _, part := range strings.Split(raw, "&") {
		if part == "" {
			return nil, errors.New("invalid query")
		}
		pair := strings.SplitN(part, "=", 2)
		name, err := url.PathUnescape(pair[0])
		if err != nil || !allow[name] {
			return nil, errors.New("invalid query")
		}
		if _, exists := values[name]; exists {
			return nil, errors.New("duplicate query")
		}
		value := ""
		if len(pair) == 2 {
			value, err = url.QueryUnescape(pair[1])
			if err != nil {
				return nil, err
			}
		}
		values[name] = value
	}
	return values, nil
}
func boundedInt(q map[string]string, key string, fallback, low, high int) (int, error) {
	raw, exists := q[key]
	if !exists {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < low || value > high {
		return 0, errors.New("invalid integer")
	}
	return value, nil
}
func identifiers(q map[string]string, key string, maximum, width int, emptyAllowed bool) ([]string, error) {
	raw, exists := q[key]
	if !exists || (emptyAllowed && raw == "") {
		return []string{}, nil
	}
	ids := strings.Split(raw, ",")
	if len(ids) > maximum {
		return nil, errors.New("too many identifiers")
	}
	for _, id := range ids {
		if len(id) > width || !identifierPattern.MatchString(id) {
			return nil, errors.New("invalid identifier")
		}
	}
	return ids, nil
}
func respondError(w http.ResponseWriter, err error) {
	status := 500
	switch {
	case errors.Is(err, corpuscore.ErrCursorExpired):
		status = 410
	case errors.Is(err, corpuscore.ErrUnavailable), errors.Is(err, corpuscore.ErrModerationUnavailable), errors.Is(err, corpuscore.ErrContractMismatch):
		status = 503
	}
	respondStatus(w, status)
}
func respondStatus(w http.ResponseWriter, status int) {
	name := "internal_error"
	switch status {
	case 400:
		name = "invalid_request"
	case 401:
		name = "unauthorized"
	case 404:
		name = "not_found"
	case 410:
		name = "cursor_expired"
	case 503:
		name = "corpus_unavailable"
	}
	writeJSON(w, status, map[string]string{"error": name}, false)
}
func writeJSON(w http.ResponseWriter, status int, value any, contract bool) {
	body, err := corpuscore.MarshalHTTP(value)
	if err != nil {
		respondStatus(w, 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if contract {
		w.Header().Set("X-Wire-Corpus-Contract", "3")
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
