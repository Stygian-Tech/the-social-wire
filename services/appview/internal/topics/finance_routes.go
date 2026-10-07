package topics

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"io"
	"net/http"
	"strconv"
)

func (r Routes) registerFinance(mux *http.ServeMux) {
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getFinance", r.finance)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getFinanceCatalog", r.financeCatalog)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.searchFinanceInstruments", r.financeSearch)
	mux.HandleFunc("GET /xrpc/app.thesocialwire.discovery.getFinanceSectors", func(w http.ResponseWriter, req *http.Request) {
		financeResponse(w, struct {
			Sectors []topicreadcore.FinanceSector `json:"sectors"`
		}{topicreadcore.FinanceSectors()})
	})
	mux.HandleFunc("POST /xrpc/app.thesocialwire.discovery.recordFinanceComposition", r.financeComposition)
}
func booleanQuery(req *http.Request, key string) (bool, error) {
	values, exists := req.URL.Query()[key]
	if !exists {
		return false, nil
	}
	if len(values) == 0 || (values[0] != "true" && values[0] != "false") {
		return false, topicreadcore.ErrInvalidCursor
	}
	return values[0] == "true", nil
}
func feedLimit(req *http.Request) (int, error) {
	value, exists := req.URL.Query()["limit"]
	if !exists {
		return 30, nil
	}
	if len(value) == 0 {
		return 0, topicreadcore.ErrInvalidCursor
	}
	n, err := strconv.Atoi(value[0])
	if err != nil || n < 1 || n > 50 {
		return 0, topicreadcore.ErrInvalidCursor
	}
	return n, nil
}
func queryCursor(req *http.Request) (string, error) {
	values, exists := req.URL.Query()["cursor"]
	if exists && (len(values) == 0 || values[0] == "") {
		return "", topicreadcore.ErrInvalidCursor
	}
	return req.URL.Query().Get("cursor"), nil
}
func (r Routes) finance(w http.ResponseWriter, req *http.Request) {
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
	if region, exists := req.URL.Query()["region"]; exists && (len(region) == 0 || region[0] != "outside-us") {
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	refresh, err := booleanQuery(req, "refreshSelections")
	if err != nil {
		fail(w, err)
		return
	}
	hide, err := booleanQuery(req, "hideCrypto")
	if err != nil {
		fail(w, err)
		return
	}
	cursor, err := queryCursor(req)
	if err != nil {
		fail(w, err)
		return
	}
	feed := "finance"
	if raw, exists := req.URL.Query()["feed"]; exists {
		feed = raw[0]
	}
	page, err := r.FinanceStore.Page(req.Context(), cursor, limit, req.URL.Query().Get("lang"), viewer, refresh, now, feed, hide)
	if err != nil {
		fail(w, err)
		return
	}
	if r.Telemetry != nil {
		r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "finance.feed.items", Value: float64(len(page.Items)), Dimensions: map[string]string{"source": page.Source, "degraded": strconv.FormatBool(page.Degraded)}, At: now})
	}
	w.Header().Set("X-Wire-Generation", page.GenerationID)
	w.Header().Set("X-Wire-Source", page.Source)
	financeResponse(w, page)
}
func (r Routes) financeCatalog(w http.ResponseWriter, req *http.Request) {
	catalog, err := r.FinanceStore.Availability(req.Context(), r.now())
	if err != nil {
		fail(w, err)
		return
	}
	financeResponse(w, catalog)
}
func (r Routes) financeSearch(w http.ResponseWriter, req *http.Request) {
	query, exists := req.URL.Query()["q"]
	if !exists || len(query) == 0 {
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	items, err := r.FinanceStore.Instruments(req.Context(), query[0], r.now())
	if err != nil {
		fail(w, err)
		return
	}
	financeResponse(w, struct {
		Instruments any `json:"instruments"`
	}{items})
}
func (r Routes) financeComposition(w http.ResponseWriter, req *http.Request) {
	if _, ok := circleAuth(w, req); !ok {
		return
	}
	var input struct {
		Event           *string `json:"event"`
		SuggestionCount *int    `json:"suggestionCount"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 1<<20))
	if decoder.Decode(&input) != nil || input.Event == nil || input.SuggestionCount == nil || *input.SuggestionCount < 0 || *input.SuggestionCount > 3 {
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	switch *input.Event {
	case "impression", "selection", "removal", "published":
	default:
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	if r.Telemetry != nil {
		r.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "finance.composition." + *input.Event, Value: 1, Dimensions: map[string]string{"suggestion_count": strconv.Itoa(*input.SuggestionCount)}, At: r.now()})
	}
	financeResponse(w, struct {
		Accepted bool `json:"accepted"`
	}{true})
}

func financeResponse(w http.ResponseWriter, value any) {
	body, err := corpuscore.MarshalHTTP(value)
	if err != nil {
		fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "private, no-store")
	w.WriteHeader(200)
	_, _ = w.Write(body)
}
