package thinappviewcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestEnrollmentFailureCountsSanitizeAndAggregate(t *testing.T) {
	secret := "did:plc:private-account Bearer SECRET private article"
	cause := &url.Error{Op: "Get", URL: "https://user:SECRET@publisher.social/private-feed?token=SECRET", Err: errors.New(secret)}
	fetch := WrapEnrollmentFailure("rss_fetch", cause.URL, 503, cause)
	err := fmt.Errorf("%s: %w", secret, errors.Join(fetch, fetch,
		WrapEnrollmentFailure("rss_backoff", cause.URL, 0, errors.New(secret)),
		WrapEnrollmentFailure("rss_parse", cause.URL, 200, errors.New(secret)),
		WrapEnrollmentFailure("rss_lease", "", 0, context.DeadlineExceeded),
		WrapEnrollmentFailure("counter_recount", "", 0, &pgconn.PgError{Code: "08006", Message: secret}),
		WrapEnrollmentFailure("pds_subscriptions", "", 0, &PDSRecordResponseError{Status: 429, Code: secret}),
		errors.New(secret)))
	got := EnrollmentFailureCounts(err)
	want := []EnrollmentFailureCount{
		{Category: "counter_recount", Kind: "database", Count: 1},
		{Category: "pds_subscriptions", Kind: "other", Status: 429, Count: 1},
		{Category: "rss_backoff", Kind: "other", Host: "publisher.social", Count: 1},
		{Category: "rss_fetch", Kind: "network", Host: "publisher.social", Status: 503, Count: 2},
		{Category: "rss_lease", Kind: "timeout", Count: 1},
		{Category: "rss_parse", Kind: "other", Host: "publisher.social", Status: 200, Count: 1},
		{Category: "unknown", Kind: "other", Count: 1},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("counts=%+v", got)
	}
	encoded, _ := json.Marshal(got)
	for _, forbidden := range []string{"SECRET", "private", "did:", "https:", "?", "Bearer", "Get"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("diagnostic leaked %q: %s", forbidden, encoded)
		}
	}
	if !errors.Is(fetch, cause) {
		t.Fatal("cause chain lost")
	}
	if len(EnrollmentFailureCounts(nil)) != 0 {
		t.Fatal("nil classified as failure")
	}
}

func TestEnrollmentFailureRejectsArbitraryDiagnosticFields(t *testing.T) {
	err := WrapEnrollmentFailure("SECRET", "https://bad%0ahost/private?SECRET", 999, context.Canceled)
	got := EnrollmentFailureCounts(err)
	want := []EnrollmentFailureCount{{Category: "unknown", Kind: "canceled", Count: 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("counts=%+v", got)
	}
	if WrapEnrollmentFailure("rss_metadata", "https://publisher.social", 200, nil) != nil {
		t.Fatal("success became failure")
	}
}

func TestEnrollmentFailureCountsExcludeRepeatedRequestContextLeaves(t *testing.T) {
	for _, abort := range []error{context.Canceled, context.DeadlineExceeded} {
		source := WrapEnrollmentFailure("rss_fetch", "https://publisher.social/feed?SECRET", 0, abort)
		err := errors.Join(source, abort, errors.Join(abort, fmt.Errorf("request ended: %w", abort)))
		got := EnrollmentFailureCounts(err)
		if len(got) != 1 || got[0].Category != "rss_fetch" || got[0].Count != 1 {
			t.Fatalf("counts=%+v", got)
		}
		if len(EnrollmentFailureCounts(errors.Join(abort, abort))) != 0 {
			t.Fatal("request abort counted as source failure")
		}
	}
}
