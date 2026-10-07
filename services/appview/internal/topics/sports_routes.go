package topics

import (
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func (r Routes) registerSports(mux *http.ServeMux) {
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getSports", r.sportsFeed)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getSportsCatalog", r.sportsCatalog)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.searchSportsEntities", r.sportsSearch)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getSportsEvents", r.sportsEvents)
}
func (r Routes) sportsFeed(w http.ResponseWriter, req *http.Request) {
	now := r.now()
	viewer, err := r.moderation(req, now)
	if err != nil {
		fail(w, err)
		return
	}
	limit, err := feedLimit(req)
	if err != nil {
		fail(w, err)
		return
	}
	var region *string
	if raw, exists := req.URL.Query()["region"]; exists {
		if len(raw) == 0 || raw[0] != "outside-us" {
			fail(w, topicreadcore.ErrInvalidCursor)
			return
		}
		region = &raw[0]
	}
	refresh, err := booleanQuery(req, "refreshSelections")
	if err != nil {
		fail(w, err)
		return
	}
	cursor, err := queryCursor(req)
	if err != nil {
		fail(w, err)
		return
	}
	feed := "sports"
	if raw, exists := req.URL.Query()["feed"]; exists {
		feed = raw[0]
	}
	page, err := r.SportsStore.Page(req.Context(), cursor, limit, req.URL.Query().Get("lang"), viewer, refresh, now, feed, region)
	if err != nil {
		fail(w, err)
		return
	}
	if r.Telemetry != nil {
		r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "sports.feed.items", Value: float64(len(page.Items)), Dimensions: map[string]string{"source": page.Source, "degraded": strconv.FormatBool(page.Degraded)}, At: now})
	}
	w.Header().Set("X-Wire-Generation", page.GenerationID)
	w.Header().Set("X-Wire-Source", page.Source)
	financeResponse(w, page)
}
func (r Routes) sportsCatalog(w http.ResponseWriter, req *http.Request) {
	value, err := r.SportsStore.Availability(req.Context(), r.now())
	if err != nil {
		fail(w, err)
		return
	}
	financeResponse(w, value)
}
func sportsSearchQuery(raw string) (string, error) {
	for _, component := range strings.Split(raw, "&") {
		parts := strings.SplitN(component, "=", 2)
		key, err := url.QueryUnescape(parts[0])
		if err != nil || !utf8.ValidString(key) {
			return "", topicreadcore.ErrInvalidCursor
		}
		if key != "q" {
			continue
		}
		if len(parts) != 2 {
			return "", topicreadcore.ErrInvalidCursor
		}
		value, err := url.QueryUnescape(parts[1])
		if err != nil || !utf8.ValidString(value) {
			return "", topicreadcore.ErrInvalidCursor
		}
		return value, nil
	}
	return "", topicreadcore.ErrInvalidCursor
}
func (r Routes) sportsSearch(w http.ResponseWriter, req *http.Request) {
	q, err := sportsSearchQuery(req.URL.RawQuery)
	if err != nil {
		fail(w, err)
		return
	}
	items, err := r.SportsStore.Entities(req.Context(), q)
	if err != nil {
		fail(w, err)
		return
	}
	financeResponse(w, struct {
		Entities any `json:"entities"`
	}{items})
}

var sportsIDPattern = regexp.MustCompile(`^[a-zA-Z0-9:_-]+$`)

func sportsIDs(req *http.Request, key string) ([]string, error) {
	values, exists := req.URL.Query()[key]
	if !exists {
		return nil, nil
	}
	raw := values[0]
	if raw == "" {
		return []string{}, nil
	}
	ids := strings.Split(raw, ",")
	if len(ids) > 100 {
		return nil, topicreadcore.ErrInvalidCursor
	}
	for _, id := range ids {
		if len(id) == 0 || len(id) > 128 || !sportsIDPattern.MatchString(id) {
			return nil, topicreadcore.ErrInvalidCursor
		}
	}
	return ids, nil
}
func (r Routes) sportsEvents(w http.ResponseWriter, req *http.Request) {
	teams, err := sportsIDs(req, "teamIDs")
	if err != nil {
		fail(w, err)
		return
	}
	preferred, err := sportsIDs(req, "preferredIDs")
	if err != nil {
		fail(w, err)
		return
	}
	zone := time.UTC
	name := "GMT"
	if raw, exists := req.URL.Query()["timeZone"]; exists {
		name = raw[0]
		if len(name) == 0 || len(name) > 128 || name == "Local" {
			fail(w, topicreadcore.ErrInvalidCursor)
			return
		}
		zone, err = time.LoadLocation(name)
		if err != nil {
			fail(w, topicreadcore.ErrInvalidCursor)
			return
		}
	}
	feed := "sports"
	if raw, exists := req.URL.Query()["feed"]; exists {
		feed = raw[0]
	}
	value, err := r.SportsStore.Events(req.Context(), feed, r.now(), teams, preferred, zone, name)
	if err != nil {
		fail(w, err)
		return
	}
	financeResponse(w, value)
}
