package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

type memoryLabelStore struct {
	targets                     []LabelTarget
	labels                      []BaselineLabel
	replacements, verifications int
}

func (s *memoryLabelStore) LoadTargets(context.Context, int, time.Time) ([]LabelTarget, error) {
	return s.targets, nil
}
func (s *memoryLabelStore) ReplaceSnapshot(_ context.Context, labels []BaselineLabel, _ []LabelerEndpoint, _ []string, _ int, _ time.Time) error {
	s.labels = labels
	s.replacements++
	return nil
}
func (s *memoryLabelStore) VerifyFresh(context.Context, []LabelerEndpoint, time.Time, time.Duration) error {
	s.verifications++
	return nil
}

type labelQueryFunc func(context.Context, LabelerEndpoint, []string, *string) (LabelPage, error)

func (f labelQueryFunc) Query(c context.Context, l LabelerEndpoint, s []string, p *string) (LabelPage, error) {
	return f(c, l, s, p)
}
func TestLabelsNegationAndAuthorityFailuresDoNotPublish(t *testing.T) {
	at := time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC)
	labelers, _ := ParseLabelers("did:example:a|https://example.com")
	positive := LabelRecord{Source: "did:example:a", Subject: "at://article", Value: "spam", CreatedAt: at.Format(time.RFC3339Nano)}
	negative := positive
	negative.Negated = true
	for _, records := range [][]LabelRecord{{positive, negative}, {negative, positive}} {
		labels, err := normalizeBaselineLabels(records, labelers, map[string]map[string]bool{"at://article": {"key": true}}, at)
		if err != nil || len(labels) != 0 {
			t.Fatalf("negation order: %v %#v", err, labels)
		}
	}
	store := &memoryLabelStore{targets: []LabelTarget{{CanonicalKey: "key", RepresentativeURI: sql.NullString{String: "at://article", Valid: true}}}}
	query := labelQueryFunc(func(context.Context, LabelerEndpoint, []string, *string) (LabelPage, error) {
		bad := positive
		bad.Source = "did:example:other"
		return LabelPage{Labels: []LabelRecord{bad}}, nil
	})
	r := BaselineLabelRefresher{Store: store, Query: query, Labelers: labelers, CandidateLimit: 5000, MaximumAge: 15 * time.Minute}
	if err := r.Refresh(context.Background(), at); err == nil || store.replacements != 0 {
		t.Fatalf("untrusted authority published: %v", err)
	}
	r.Query = labelQueryFunc(func(context.Context, LabelerEndpoint, []string, *string) (LabelPage, error) {
		return LabelPage{}, errors.New("upstream unavailable")
	})
	if err := r.Refresh(context.Background(), at); err == nil || store.replacements != 0 {
		t.Fatalf("failed query published: %v", err)
	}
}
func TestLabelsEmptyCorpusProbesAndThrottleVerifies(t *testing.T) {
	labelers, _ := ParseLabelers("did:example:a|https://example.com")
	store := &memoryLabelStore{}
	calls := 0
	r := BaselineLabelRefresher{Store: store, Labelers: labelers, CandidateLimit: 5, MaximumAge: 15 * time.Minute, Query: labelQueryFunc(func(_ context.Context, _ LabelerEndpoint, subjects []string, _ *string) (LabelPage, error) {
		calls++
		if len(subjects) != 1 || subjects[0] != "did:example:the-social-wire-label-probe" {
			t.Fatalf("missing empty-corpus probe")
		}
		return LabelPage{Labels: []LabelRecord{}}, nil
	})}
	at := time.Now()
	if err := r.Refresh(context.Background(), at); err != nil {
		t.Fatal(err)
	}
	if err := r.Refresh(context.Background(), at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if calls != 1 || store.replacements != 1 || store.verifications != 2 {
		t.Fatalf("counts %d %d %d", calls, store.replacements, store.verifications)
	}
}
func TestLabelsPaginationCannotPublishIncompleteSnapshot(t *testing.T) {
	labelers, _ := ParseLabelers("did:example:a|https://example.com")
	cursor := "same"
	store := &memoryLabelStore{}
	r := BaselineLabelRefresher{Store: store, Labelers: labelers, CandidateLimit: 5, Query: labelQueryFunc(func(context.Context, LabelerEndpoint, []string, *string) (LabelPage, error) {
		return LabelPage{Cursor: &cursor, Labels: []LabelRecord{}}, nil
	})}
	if err := r.Refresh(context.Background(), time.Now()); err == nil || store.replacements != 0 {
		t.Fatalf("repeated cursor published %v", err)
	}
}
func TestHTTPLabelsBoundsAndQueryContract(t *testing.T) {
	transport := labelRoundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/xrpc/com.atproto.label.queryLabels" || r.URL.Query().Get("sources") != "did:example:a" || r.URL.Query().Get("limit") != "250" {
			t.Errorf("wrong query %s", r.URL)
		}
		body := `{"labels":[]}`
		if r.URL.Query().Get("cursor") == "oversized" {
			body = strings.Repeat("x", 2*1024*1024+1)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: http.Header{}}, nil
	})
	u, _ := url.Parse("https://example.com")
	q := HTTPLabelQuery{Client: &http.Client{Transport: transport}}
	l := LabelerEndpoint{SourceDID: "did:example:a", BaseURL: u}
	if _, err := q.Query(context.Background(), l, []string{"at://subject"}, nil); err != nil {
		t.Fatal(err)
	}
	oversized := "oversized"
	if _, err := q.Query(context.Background(), l, []string{"at://subject"}, &oversized); err == nil {
		t.Fatal("oversized response accepted")
	}
}

type labelRoundTripFunc func(*http.Request) (*http.Response, error)

func (f labelRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
