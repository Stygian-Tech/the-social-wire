package reader

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/listcore"
)

func TestListFeedUsesListBoundCursorAndClassifiesWarming(t *testing.T) {
	for _, test := range []struct {
		err    error
		status int
	}{{nil, 200}, {listcore.ErrWarming, 503}, {listcore.ErrCursor, 400}, {listcore.ErrMissing, 404}} {
		called := false
		mux := http.NewServeMux()
		Routes{ListFeed: func(ctx context.Context, auth gatewaycore.AuthContext, id, filter, cursor string, limit int, at time.Time) (*appviewcore.FeedPage, error) {
			called = true
			if auth.DID != "viewer" || id != "list" || cursor != "list-bound-cursor" || filter != "all" || limit != 50 {
				t.Fatal("bad list arguments")
			}
			return &appviewcore.FeedPage{}, test.err
		}}.Register(mux)
		request := httptest.NewRequest("GET", "/v1/appview/feed?kind=list&id=list&cursor=list-bound-cursor", nil)
		request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: "viewer"}))
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, request)
		if !called || response.Code != test.status {
			t.Fatal("list dispatch", called, response.Code)
		}
	}
}
