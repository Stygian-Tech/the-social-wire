package topics

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSportsSearchFormAndMalformedQuery(t *testing.T) {
	for _, entry := range []struct{ raw, want string }{{"q=Real+Madrid", "Real Madrid"}, {"q=C%2B%2B", "C++"}, {"unused=%ZZ&q=Club", "Club"}, {"q=First&q=Second", "First"}} {
		value, err := sportsSearchQuery(entry.raw)
		if err != nil || value != entry.want {
			t.Fatal(entry, value, err)
		}
	}
	for _, raw := range []string{"q", "q=%ZZ", "q=%FF", "%ZZ=x&q=Club", "other=yes"} {
		if _, err := sportsSearchQuery(raw); err == nil {
			t.Fatal(raw)
		}
	}
}
func TestSportsRoutesBoundsAndDisabledEvents(t *testing.T) {
	mux := http.NewServeMux()
	Routes{Moderation: topicreadcore.NewModerationService(nil, nil), SportsStore: &topicreadcore.SportsStore{Config: topicreadcore.SportsConfig{Mode: "visible", EventsEnabled: false}}}.Register(mux)
	for _, query := range []string{"teamIDs=a,,b", "teamIDs=" + strings.Repeat("a", 129), "timeZone=Local", "timeZone=Not_A_Zone", "preferredIDs=%3Cscript%3E"} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getSportsEvents?"+query, nil))
		if w.Code != 400 {
			t.Fatal(query, w.Code, w.Body.String())
		}
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getSportsEvents?teamIDs=&timeZone=UTC", nil))
	var body map[string]any
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || body["degraded"] != false || body["schedulesStatus"] != "unavailable" || len(body["events"].([]any)) != 0 || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Vary") != "" {
		t.Fatal(w.Code, w.Header(), w.Body.String())
	}
	for _, query := range []string{"limit=0", "limit=51", "region=us", "refreshSelections=yes", "cursor="} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery.getSports?"+query, nil))
		if w.Code != 400 {
			t.Fatal(query, w.Code, w.Body.String())
		}
	}
}
