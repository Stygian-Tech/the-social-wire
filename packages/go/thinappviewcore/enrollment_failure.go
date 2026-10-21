package thinappviewcore

import (
	"context"
	"errors"
	"net"
	"net/url"
	"sort"
	"strings"
)

// EnrollmentFailure retains the cause for errors.Is/As while exposing only
// explicitly selected operational context to enrollment diagnostics.
type EnrollmentFailure struct {
	category, host string
	status         int
	cause          error
}

func (e *EnrollmentFailure) Error() string { return e.cause.Error() }
func (e *EnrollmentFailure) Unwrap() error { return e.cause }

// WrapEnrollmentFailure never retains a URL, credentials, path or query in its
// diagnostic fields. Callers must supply a static category from the allowlist.
func WrapEnrollmentFailure(category, endpoint string, status int, cause error) error {
	if cause == nil {
		return nil
	}
	switch category {
	case "rss_backoff", "rss_fetch", "rss_parse", "rss_lease", "rss_metadata", "rss_store", "rss_admission", "pds_subscriptions", "pds_author", "pds_resolve", "pds_fetch", "pds_parse", "pds_store", "pds_limit", "unavailable", "counter_scopes", "counter_lease", "counter_recount", "counter_cache":
	default:
		category = "unknown"
	}
	host := ""
	if u, err := url.Parse(endpoint); err == nil && (u.Scheme == "https" || u.Scheme == "http") {
		candidate := strings.ToLower(u.Hostname())
		// A hostname is the only permitted upstream identifier. Reject malformed
		// authorities rather than allowing arbitrary caller text into logs.
		if len(candidate) <= 253 && candidate != "" {
			valid := true
			for _, c := range candidate {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '-') {
					valid = false
				}
			}
			if valid {
				host = candidate
			}
		}
	}
	var response *PDSRecordResponseError
	if status == 0 && errors.As(cause, &response) {
		status = response.Status
	}
	if status < 100 || status > 599 {
		status = 0
	}
	return &EnrollmentFailure{category: category, host: host, status: status, cause: cause}
}

type EnrollmentFailureCount struct {
	Category string `json:"category"`
	Kind     string `json:"kind"`
	Host     string `json:"host,omitempty"`
	Status   int    `json:"status,omitempty"`
	Count    int    `json:"count"`
}

// EnrollmentFailureCounts walks joined errors without stringifying any cause.
// A typed boundary counts once even when its cause joins multiple low-level
// errors; separate source/metadata failures remain separate aggregate entries.
// Bare context leaves are request bookkeeping, often joined at several layers,
// and are excluded. Typed source failures retain their category even on abort.
func EnrollmentFailureCounts(err error) []EnrollmentFailureCount {
	type key struct {
		category, kind, host string
		status               int
	}
	counts := map[key]int{}
	var visit func(error)
	visit = func(err error) {
		if err == nil {
			return
		}
		if e, ok := err.(*EnrollmentFailure); ok {
			counts[key{e.category, enrollmentErrorKind(e.cause), e.host, e.status}]++
		} else if joined, ok := err.(interface{ Unwrap() []error }); ok {
			for _, child := range joined.Unwrap() {
				visit(child)
			}
		} else if wrapped, ok := err.(interface{ Unwrap() error }); ok {
			visit(wrapped.Unwrap())
		} else if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			counts[key{"unknown", enrollmentErrorKind(err), "", 0}]++
		}
	}
	visit(err)
	result := make([]EnrollmentFailureCount, 0, len(counts))
	for k, n := range counts {
		result = append(result, EnrollmentFailureCount{k.category, k.kind, k.host, k.status, n})
	}
	sort.Slice(result, func(i, j int) bool {
		a, b := result[i], result[j]
		if a.Category != b.Category {
			return a.Category < b.Category
		}
		if a.Kind != b.Kind {
			return a.Kind < b.Kind
		}
		if a.Host != b.Host {
			return a.Host < b.Host
		}
		return a.Status < b.Status
	})
	return result
}

func enrollmentErrorKind(err error) string {
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var database interface{ SQLState() string }
	if errors.As(err, &database) {
		return "database"
	}
	var network net.Error
	if errors.As(err, &network) {
		if network.Timeout() {
			return "timeout"
		}
		return "network"
	}
	return "other"
}
