package topicreadcore

import (
	"context"
	"encoding/json"
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
	cursors  []string
	wait     bool
}

func (f *followTransport) Get(ctx context.Context, target string, headers http.Header, max, redirects int) (int, http.Header, []byte, error) {
	if max != 1<<20 || redirects != 0 || headers.Get("Authorization") != "" || headers.Get("DPoP") != "" {
		return 0, nil, nil, errors.New("credentials sent on public request")
	}
	u, _ := url.Parse(target)
	if u.Scheme != "https" || u.Host != "pds.example" || u.Path != "/xrpc/com.atproto.repo.listRecords" || u.Query().Get("repo") != "viewer" || u.Query().Get("limit") != "100" || u.Query().Get("reverse") != "false" || u.Query().Get("collection") != "app.bsky.graph.follow" {
		return 0, nil, nil, errors.New("invalid query")
	}
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > 25*time.Second {
		return 0, nil, nil, errors.New("missing bound")
	}
	index := f.calls
	f.calls++
	f.cursors = append(f.cursors, u.Query().Get("cursor"))
	if f.wait {
		<-ctx.Done()
		return 0, nil, nil, ctx.Err()
	}
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
	}{{"empty", []string{`{"records":[]}`}, 0}, {"pages", []string{`{"records":[{"value":{"subject":"did:example:a"}}],"cursor":"next-page"}`, `{"records":[{"value":{"subject":"did:example:b"}}]}`}, 2}} {
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
			if fixture.count == 2 && (transport.calls != 2 || transport.cursors[1] != "next-page") {
				t.Fatal("public follow pagination did not advance", transport.cursors)
			}
		})
	}
}

func TestCircleViewerFollowReadsMoreThanOneHundredWithoutCredentials(t *testing.T) {
	records := make([]map[string]any, 100)
	for index := range records {
		records[index] = map[string]any{"value": map[string]any{"subject": "did:example:" + time.Unix(int64(index), 0).Format("150405")}}
	}
	first, err := json.Marshal(map[string]any{"records": records, "cursor": "next-page"})
	if err != nil {
		t.Fatal(err)
	}
	transport := &followTransport{statuses: []int{200, 200}, bodies: []string{string(first), `{"records":[{"value":{"subject":"did:example:last"}}]}`}}
	reader := CircleReader{Moderation: NewModerationService(fixedResolver("https://pds.example"), transport), Auth: gatewaycore.AuthContext{DID: "viewer", Authorization: "Bearer private"}, FollowProof: "single-use-proof"}
	list, err := reader.ViewerFollows(context.Background(), "viewer")
	if err != nil || !list.Complete || len(list.FolloweeDIDs) != 101 || transport.calls != 2 || transport.cursors[1] != "next-page" {
		t.Fatal(list, err, transport.cursors)
	}
}

func TestCircleViewerFollowIncompletePagesAndCursorCyclesFailClosed(t *testing.T) {
	for _, fixture := range []struct {
		name     string
		bodies   []string
		statuses []int
	}{
		{"later-page-failure", []string{`{"records":[{"value":{"subject":"did:example:a"}}],"cursor":"a"}`, `{}`}, []int{200, 503}},
		{"later-page-malformed", []string{`{"records":[],"cursor":"a"}`, `{"records":null}`}, []int{200, 200}},
		{"empty-cursor", []string{`{"records":[],"cursor":""}`}, []int{200}},
		{"invalid-cursor", []string{`{"records":[],"cursor":123}`}, []int{200}},
		{"repeated-cursor", []string{`{"records":[],"cursor":"a"}`, `{"records":[],"cursor":"a"}`}, []int{200, 200}},
		{"cycle-cursor", []string{`{"records":[],"cursor":"a"}`, `{"records":[],"cursor":"b"}`, `{"records":[],"cursor":"a"}`}, []int{200, 200, 200}},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			transport := &followTransport{bodies: fixture.bodies, statuses: fixture.statuses}
			reader := CircleReader{Moderation: NewModerationService(fixedResolver("https://pds.example"), transport), Auth: gatewaycore.AuthContext{DID: "viewer", Authorization: "Bearer private"}, FollowProof: "follow-proof"}
			list, err := reader.ViewerFollows(context.Background(), "viewer")
			if err == nil || list.Complete || len(list.FolloweeDIDs) != 0 || transport.calls != len(fixture.bodies) {
				t.Fatal("incomplete graph accepted", list, err, transport.calls)
			}
		})
	}
}

func TestCircleViewerFollowCancellationAndViewerBinding(t *testing.T) {
	for _, fixture := range []struct {
		name string
		ctx  func() (context.Context, context.CancelFunc)
		want error
	}{
		{"canceled", func() (context.Context, context.CancelFunc) {
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			return ctx, cancel
		}, context.Canceled},
		{"deadline", func() (context.Context, context.CancelFunc) {
			return context.WithTimeout(context.Background(), 10*time.Millisecond)
		}, context.DeadlineExceeded},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			ctx, cancel := fixture.ctx()
			defer cancel()
			transport := &followTransport{wait: true}
			reader := CircleReader{Moderation: NewModerationService(fixedResolver("https://pds.example"), transport), Auth: gatewaycore.AuthContext{DID: "viewer"}, FollowProof: "follow-proof"}
			if list, err := reader.ViewerFollows(ctx, "viewer"); !errors.Is(err, fixture.want) || list.Complete {
				t.Fatal(list, err)
			}
		})
	}
	transport := &followTransport{}
	reader := CircleReader{Moderation: NewModerationService(fixedResolver("https://pds.example"), transport), Auth: gatewaycore.AuthContext{DID: "viewer"}, FollowProof: "follow-proof"}
	if _, err := reader.ViewerFollows(context.Background(), "another-viewer"); err == nil || transport.calls != 0 {
		t.Fatal("authenticated viewer binding lost", err, transport.calls)
	}
}

func TestCircleViewerFollowPaginationIsBounded(t *testing.T) {
	transport := &followTransport{}
	for index := 0; index < 201; index++ {
		transport.statuses = append(transport.statuses, 200)
		transport.bodies = append(transport.bodies, `{"records":[],"cursor":"`+time.Unix(int64(index), 0).Format(time.RFC3339)+`"}`)
	}
	reader := CircleReader{Moderation: NewModerationService(fixedResolver("https://pds.example"), transport), Auth: gatewaycore.AuthContext{DID: "viewer"}, FollowProof: "follow-proof"}
	if list, err := reader.ViewerFollows(context.Background(), "viewer"); err == nil || list.Complete || transport.calls != 200 {
		t.Fatal("unbounded follow pagination", list, err, transport.calls)
	}
}
