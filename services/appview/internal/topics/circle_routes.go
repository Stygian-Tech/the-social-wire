package topics

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"io"
	"net/http"
)

func circleAuth(w http.ResponseWriter, req *http.Request) (gatewaycore.AuthContext, bool) {
	a, ok := gatewaycore.AuthContextFrom(req.Context())
	if !ok || a.DID == gatewaycore.AnonymousDiscoveryDID {
		w.WriteHeader(401)
		return gatewaycore.AuthContext{}, false
	}
	return a, true
}
func privateResponse(w http.ResponseWriter, value any) {
	body, err := corpuscore.MarshalHTTP(value)
	if err != nil {
		fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Vary", "Authorization, Accept-Language")
	w.WriteHeader(200)
	_, _ = w.Write(body)
}
func (r Routes) circleCatalog(w http.ResponseWriter, req *http.Request) {
	if _, ok := circleAuth(w, req); !ok {
		return
	}
	catalog, err := r.Circle.Catalog(req.Context(), r.now())
	if err != nil {
		fail(w, err)
		return
	}
	privateResponse(w, catalog)
}
func (r Routes) circleEdition(w http.ResponseWriter, req *http.Request) {
	a, ok := circleAuth(w, req)
	if !ok {
		return
	}
	edition, err := r.Circle.Edition(req.Context(), a, req.Header.Get("X-Circle-Graph-DPoP"), topicreadcore.PrimaryLanguage(req.URL.Query().Get("lang")), req.URL.Query().Get("cursor"), r.now())
	if err != nil {
		fail(w, err)
		return
	}
	privateResponse(w, edition)
}
func (r Routes) circleHidden(w http.ResponseWriter, req *http.Request) {
	a, ok := circleAuth(w, req)
	if !ok {
		return
	}
	var input struct {
		StoryID *string `json:"storyId"`
		Hidden  *bool   `json:"hidden"`
	}
	decoder := json.NewDecoder(io.LimitReader(req.Body, 1<<20))
	if decoder.Decode(&input) != nil || input.StoryID == nil || input.Hidden == nil {
		fail(w, topicreadcore.ErrInvalidCursor)
		return
	}
	id, err := r.Circle.State.SetHidden(req.Context(), a.DID, *input.StoryID, *input.Hidden, r.now())
	if err != nil {
		fail(w, err)
		return
	}
	privateResponse(w, struct {
		StoryID string `json:"storyId"`
		Hidden  bool   `json:"hidden"`
	}{id, *input.Hidden})
}
