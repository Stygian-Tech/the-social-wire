package operationscore

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"testing"
	"time"
)

func TestTransientRenewalClassification(t *testing.T) {
	for _, code := range []string{"55P03", "57014", "40P01", "40001", "08000", "08006", "57P01"} {
		if !TransientLeaseFailure(&pgconn.PgError{Code: code}) {
			t.Fatalf("did not retry %s", code)
		}
	}
	for _, err := range []error{ErrLeaseConflict, ErrAuthorityExpired, context.Canceled, errors.New("unknown"), &pgconn.PgError{Code: "23505"}} {
		if TransientLeaseFailure(err) {
			t.Fatalf("retried permanent error %v", err)
		}
	}
	if !TransientLeaseFailure(context.DeadlineExceeded) {
		t.Fatal("deadline should retry with remaining authority")
	}
}

func TestRenewalRetriesTransientFailureAndReportsEvidence(t *testing.T) {
	calls := 0
	store := &supervisorStore{renew: func(context.Context) (FencedRoleLease, error) {
		calls++
		if calls == 1 {
			return FencedRoleLease{}, &pgconn.PgError{Code: "40001"}
		}
		return testLease(), nil
	}}
	supervisor := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
	deadline := time.Now().Add(10 * time.Second)
	if _, _, err := supervisor.renewWithRetry(context.Background(), testLease().RoleLeaseAuthority, func() time.Time { return deadline }); err != nil || calls != 2 {
		t.Fatalf("retry: calls=%d err=%v", calls, err)
	}
}
func TestRenewalDoesNotRetryWithoutCompleteBudget(t *testing.T) {
	calls := 0
	store := &supervisorStore{renew: func(context.Context) (FencedRoleLease, error) {
		calls++
		return FencedRoleLease{}, context.DeadlineExceeded
	}}
	supervisor := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
	deadline := time.Now().Add(4 * time.Second)
	if _, _, err := supervisor.renewWithRetry(context.Background(), testLease().RoleLeaseAuthority, func() time.Time { return deadline }); err == nil || calls != 1 {
		t.Fatalf("unsafe retry: calls=%d err=%v", calls, err)
	}
}
