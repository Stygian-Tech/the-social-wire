package topicreadcore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

type followTransport struct {
	statuses []int
	bodies   []string
	calls    int
}

func (f *followTransport) Get(ctx context.Context, target string, headers http.Header, max, redirects int) (int, http.Header, []byte, error) {
	if max != 1<<20 || redirects != 0 || headers.Get("Authorization") != "Bearer private" || headers.Get("DPoP") != "follow-proof" {
		return 0, nil, nil, errors.New("invalid private request")
	}
	u, _ := url.Parse(target)
	if u.Query().Get("limit") != "100" || u.Query().Get("reverse") != "false" || u.Query().Get("collection") != "app.bsky.graph.follow" {
		return 0, nil, nil, errors.New("invalid query")
	}
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > 25*time.Second {
		return 0, nil, nil, errors.New("missing bound")
	}
	index := f.calls
	f.calls++
	if index >= len(f.statuses) {
		return 0, nil, nil, errors.New("unexpected page")
	}
	return f.statuses[index], nil, []byte(f.bodies[index]), nil
}
func TestCircleViewerFollowUpstreamFailuresNeverClaimEmptyCompleteGraph(t *testing.T) {
	for _, fixture := range []struct {
		name   string
		status int
		body   string
	}{{"unauthorized", 401, `{}`}, {"unavailable", 503, `{}`}, {"malformed", 200, `{`}, {"missing-records", 200, `{}`}, {"null-records", 200, `{"records":null}`}} {
		t.Run(fixture.name, func(t *testing.T) {
			transport := &followTransport{statuses: []int{fixture.status}, bodies: []string{fixture.body}}
			m := NewModerationService(fixedResolver("https://pds.example"), transport)
			r := CircleReader{Moderation: m, Auth: gatewaycore.AuthContext{DID: "viewer", Authorization: " Bearer private "}, FollowProof: "follow-proof"}
			if list, err := r.ViewerFollows(context.Background(), "viewer"); err == nil || list.Complete {
				t.Fatal(list, err)
			}
		})
	}
}
func TestCircleViewerFollowValidEmptyAndContinuation(t *testing.T) {
	for _, fixture := range []struct {
		name   string
		bodies []string
		count  int
	}{{"empty", []string{`{"records":[]}`}, 0}, {"pages", []string{`{"records":[{"value":{"subject":"did:example:a"}}],"cursor":""}`, `{"records":[{"value":{"subject":"did:example:b"}}]}`}, 2}} {
		t.Run(fixture.name, func(t *testing.T) {
			transport := &followTransport{bodies: fixture.bodies, statuses: make([]int, len(fixture.bodies))}
			for i := range transport.statuses {
				transport.statuses[i] = 200
			}
			m := NewModerationService(fixedResolver("https://pds.example"), transport)
			r := CircleReader{Moderation: m, Auth: gatewaycore.AuthContext{DID: "viewer", Authorization: "Bearer private"}, FollowProof: "follow-proof"}
			list, err := r.ViewerFollows(context.Background(), "viewer")
			if err != nil || !list.Complete || len(list.FolloweeDIDs) != fixture.count {
				t.Fatal(list, err)
			}
			if strings.Contains(strings.Join(list.FolloweeDIDs, ","), "private") {
				t.Fatal("invalid follow parsing")
			}
		})
	}
}
