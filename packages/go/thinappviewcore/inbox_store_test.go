package thinappviewcore

import (
	"strings"
	"testing"
)

func TestInboxLeaseTokensAreIndependent(t *testing.T) {
	a, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	b, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 32 || len(b) != 32 || a == b {
		t.Fatalf("invalid lease tokens %q %q", a, b)
	}
}
func TestInboxFailureReasonBoundsUnicode(t *testing.T) {
	reason := strings.Repeat("é", 1001)
	result := truncateInboxReason(reason)
	if len([]rune(result)) != 1000 || !strings.HasSuffix(result, "é") {
		t.Fatal("reason must retain complete Unicode code points")
	}
}
func TestInboxSQLRetainsAuthoritativeFences(t *testing.T) {
	for _, sql := range []string{inboxAppliedSQL, inboxRetrySQL, inboxRenewSQL, inboxDeadLetterSQL} {
		for _, fence := range []string{"status = 'leased'", "lease_owner =", "lease_token ="} {
			if !strings.Contains(sql, fence) {
				t.Fatalf("missing %s", fence)
			}
		}
	}
	for _, fence := range []string{"FOR UPDATE SKIP LOCKED", "earlier.seq < i.seq", "appview_ingestion_reconciliation_requests", "appview_publication_scopes", "finance_selection_sync", "sports_selection_sync"} {
		if !strings.Contains(inboxClaimSQL, fence) {
			t.Fatalf("missing claim fence %s", fence)
		}
	}
	if !strings.Contains(inboxWatermarkSQL, "reconciled_at IS NULL") || !strings.Contains(inboxWatermarkSQL, "filtered_scope") {
		t.Fatal("watermark must retain reconciliation barriers and terminal filtering")
	}
}
