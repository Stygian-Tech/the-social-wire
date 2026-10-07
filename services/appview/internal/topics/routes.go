package topics

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"net/http"
	"strconv"
	"time"
)

type CatalogProvider interface {
	Availability(context.Context, time.Time) (any, bool, error)
}
type Routes struct {
	FinanceStore    *topicreadcore.FinanceStore
	SportsStore     *topicreadcore.SportsStore
	Circle          *topicreadcore.CircleService
	Wire            *topicreadcore.WireStore
	Moderation      *topicreadcore.ModerationService
	Telemetry       *telemetrycore.TelemetryBuffer
	WireVisible     bool
	Finance, Sports CatalogProvider
	Now             func() time.Time
}

func (r Routes) Register(mux *http.ServeMux) {
	if r.SportsStore != nil {
		r.registerSports(mux)
	}
	if r.FinanceStore != nil {
		r.registerFinance(mux)
	}
	if r.Circle != nil {
		mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getCircleCatalog", r.circleCatalog)
		mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getCircleEdition", r.circleEdition)
		mux.HandleFunc("POST /xrpc/app.thesocialwire.discovery.setCircleItemHidden", r.circleHidden)
	}
	if r.Wire == nil {
		return
	}
	if r.WireVisible {
		mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getWire", r.feed)
		mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getWireEdition", r.edition)
	}
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getWireItem", r.item)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getFeedCatalog", r.catalog)
}
func (r Routes) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}
func auth(req *http.Request) (*gatewaycore.AuthContext, string) {
	a, ok := gatewaycore.AuthContextFrom(req.Context())
	if !ok || a.DID == gatewaycore.AnonymousDiscoveryDID {
		return nil, ""
	}
	return &a, a.DID
}
func (r Routes) moderation(req *http.Request, now time.Time) (string, error) {
	a, viewer := auth(req)
	if r.Moderation == nil {
		return "", topicreadcore.ErrModerationUnavailable
	}
	_, err := r.Moderation.Require(req.Context(), a, req.Header.Get("X-Wire-Moderation-DPoP"), now)
	return viewer, err
}
func fail(w http.ResponseWriter, err error) {
	status := 503
	if errors.Is(err, topicreadcore.ErrInvalidCursor) {
		status = 400
	} else if errors.Is(err, topicreadcore.ErrCursorExpired) {
		status = 410
	} else if errors.Is(err, topicreadcore.ErrItemNotFound) {
		status = 404
	}
	w.WriteHeader(status)
}
func response(w http.ResponseWriter, req *http.Request, value any, etag string, viewer bool, generation, source string) error {
	body, err := corpuscore.MarshalHTTP(value)
	if err != nil {
		return err
	}
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("ETag", etag)
	h.Set("Vary", "Authorization, Accept-Language")
	if viewer {
		h.Set("Cache-Control", "private, max-age=0")
	} else {
		h.Set("Cache-Control", "public, max-age=60, stale-while-revalidate=300")
	}
	if generation != "" {
		h.Set("X-Wire-Generation", generation)
	}
	if source != "" {
		h.Set("X-Wire-Source", source)
	}
	if !viewer && req.Header.Get("If-None-Match") == etag {
		w.WriteHeader(304)
		return nil
	}
	w.WriteHeader(200)
	_, err = w.Write(body)
	return err
}
func (r Routes) feed(w http.ResponseWriter, req *http.Request) {
	now := r.now()
	viewer, err := r.moderation(req, now)
	if err != nil {
		fail(w, err)
		return
	}
	limit := 30
	if raw, ok := req.URL.Query()["limit"]; ok {
		limit, err = strconv.Atoi(raw[0])
		if err != nil || limit < 1 || limit > 50 {
			fail(w, topicreadcore.ErrInvalidCursor)
			return
		}
	}
	cursor, err := queryCursor(req)
	if err != nil {
		fail(w, err)
		return
	}
	p, err := r.Wire.Feed(req.Context(), cursor, limit, req.URL.Query().Get("lang"), viewer, now)
	if err != nil {
		fail(w, err)
		return
	}
	next := "end"
	if p.Cursor != nil {
		next = *p.Cursor
	}
	if err = response(w, req, p, "\"wire-"+p.GenerationID+"-"+next+"\"", viewer != "", p.GenerationID, p.Source); err != nil {
		fail(w, err)
	}
}
func (r Routes) edition(w http.ResponseWriter, req *http.Request) {
	started := r.now()
	viewer, err := r.moderation(req, started)
	if err != nil {
		fail(w, err)
		return
	}
	var region *string
	key := "default"
	if raw, ok := req.URL.Query()["region"]; ok {
		if raw[0] != "outside-us" {
			fail(w, topicreadcore.ErrInvalidCursor)
			return
		}
		region = &raw[0]
		key = *region
	}
	e, err := r.Wire.Edition(req.Context(), req.URL.Query().Get("lang"), region, viewer, r.now())
	if err != nil {
		fail(w, err)
		return
	}
	r.recordEdition(e, r.now().Sub(started), viewer != "")
	if err = response(w, req, topicreadcore.EditionResponse(e), "\"wire-edition-"+e.GenerationID+"-"+key+"\"", viewer != "", e.GenerationID, e.Source); err != nil {
		fail(w, err)
	}
}
func (r Routes) item(w http.ResponseWriter, req *http.Request) {
	now := r.now()
	viewer, err := r.moderation(req, now)
	if err != nil {
		fail(w, err)
		return
	}
	id := req.URL.Query().Get("itemId")
	if id == "" || len(id) > 128 {
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	detail, err := r.Wire.Item(req.Context(), id, viewer, now)
	if err != nil {
		fail(w, err)
		return
	}
	if detail == nil {
		fail(w, topicreadcore.ErrItemNotFound)
		return
	}
	if err = response(w, req, detail, "\"wire-item-"+detail.Item.ItemID+"\"", viewer != "", "", ""); err != nil {
		fail(w, err)
	}
}
func (r Routes) catalog(w http.ResponseWriter, req *http.Request) {
	now := r.now()
	catalog, err := r.Wire.Catalog(req.Context(), now)
	if err != nil {
		fail(w, err)
		return
	}
	finance := any(map[string]any{"enabled": false, "available": false, "widgetsEnabled": false, "feeds": []any{}})
	sports := any(map[string]any{"enabled": false, "available": false, "eventsEnabled": false, "feeds": []any{}, "entities": []any{}, "version": "sports-named-feeds-v2"})
	fa, sa := false, false
	if r.FinanceStore != nil {
		value, e := r.FinanceStore.Availability(req.Context(), now)
		if e != nil {
			fail(w, e)
			return
		}
		finance = value
		fa = value.Available
	} else if r.Finance != nil {
		finance, fa, err = r.Finance.Availability(req.Context(), now)
		if err != nil {
			fail(w, err)
			return
		}
	}
	if r.SportsStore != nil {
		value, e := r.SportsStore.Availability(req.Context(), now)
		if e != nil {
			fail(w, e)
			return
		}
		sports = value
		sa = value.Available
	} else if r.Sports != nil {
		sports, sa, err = r.Sports.Availability(req.Context(), now)
		if err != nil {
			fail(w, err)
			return
		}
	}
	result := combinedCatalog{Enabled: r.WireVisible && catalog.Enabled, Available: r.WireVisible && catalog.Available, Title: "The Wire", Subtitle: "Important stories across the social web", SupportedLanguages: catalog.SupportedLanguages, LatestGenerationID: catalog.LatestGenerationID, GeneratedAt: catalog.GeneratedAt, FinanceAvailable: fa, Finance: finance, SportsAvailable: sa, Sports: sports}
	latest := "none"
	if catalog.LatestGenerationID != nil {
		latest = *catalog.LatestGenerationID
	}
	_, viewer := auth(req)
	generation := ""
	if latest != "none" {
		generation = latest
	}
	if err = response(w, req, result, "\"wire-catalog-"+latest+"-"+strconv.FormatBool(catalog.Enabled)+"\"", viewer != "", generation, ""); err != nil {
		fail(w, err)
	}
}
func (r Routes) recordEdition(e wirecore.Edition, latency time.Duration, authenticated bool) {
	if r.Telemetry == nil {
		return
	}
	base := map[string]string{"algorithm": e.AlgorithmVersion, "source": e.Source, "degraded": strconv.FormatBool(e.Degraded), "auth": "public"}
	if authenticated {
		base["auth"] = "viewer"
	}
	metric := func(name string, value float64, dims map[string]string) {
		r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: name, Value: value, Dimensions: dims, At: r.now()})
	}
	metric("wire.edition.endpoint.latency_ms", float64(latency)/float64(time.Millisecond), base)
	for _, fill := range []struct {
		name          string
		count, target int
	}{{"top_stories", len(e.LeadStories), 4}, {"publication_spotlights", len(e.PublicationPanels), 6}, {"people", len(e.TalkedAboutAccounts), 10}, {"trending", len(e.TrendingStories), 10}} {
		dims := map[string]string{}
		for k, v := range base {
			dims[k] = v
		}
		dims["section"] = fill.name
		metric("wire.edition.section.fill", float64(fill.count), dims)
		metric("wire.edition.section.underfill", float64(max(0, fill.target-fill.count)), dims)
	}
	total, largest := 0, 0
	for _, panel := range e.PublicationPanels {
		total += len(panel.Stories)
		largest = max(largest, len(panel.Stories))
	}
	concentration := 0.
	if total > 0 {
		concentration = float64(largest) / float64(total)
	}
	metric("wire.edition.publication.concentration", concentration, base)
}

type combinedCatalog struct {
	Enabled            bool       `json:"enabled"`
	Available          bool       `json:"available"`
	Title              string     `json:"title"`
	Subtitle           string     `json:"subtitle"`
	SupportedLanguages []string   `json:"supportedLanguages"`
	LatestGenerationID *string    `json:"latestGenerationId,omitempty"`
	GeneratedAt        *time.Time `json:"generatedAt,omitempty"`
	FinanceAvailable   bool       `json:"financeAvailable"`
	Finance            any        `json:"finance"`
	SportsAvailable    bool       `json:"sportsAvailable"`
	Sports             any        `json:"sports"`
}
