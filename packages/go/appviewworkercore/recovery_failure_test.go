package appviewworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestRecoveryFailureCategoriesExcludeSensitiveMessages(t *testing.T) {
	for _, test := range []struct {
		err  error
		want string
	}{
		{fmt.Errorf("private DID: %w", context.DeadlineExceeded), "deadline_exceeded"},
		{context.Canceled, "cancelled"},
		{thinappviewcore.ErrStaleInboxLease, "stale_lease"},
		{thinappviewcore.ErrInvalidInboxRow, "invalid_checkpoint"},
		{&json.UnmarshalTypeError{Value: "private record", Type: nil}, "malformed_json"},
		{&pgconn.PgError{Message: "private record"}, "database_failed"},
		{&net.DNSError{Err: "private hostname"}, "transport_failed"},
		{errors.New("https://private.example/did:plc:secret"), "restoration_failed"},
	} {
		if got := recoveryFailureCategory(test.err); got != test.want {
			t.Fatalf("got %q want %q", got, test.want)
		}
	}
}
