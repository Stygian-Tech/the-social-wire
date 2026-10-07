package appviewworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"net"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

// Categories are closed and never include transport messages, record bodies or identifiers.
func recoveryFailureCategory(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline_exceeded"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, thinappviewcore.ErrStaleInboxLease):
		return "stale_lease"
	case errors.Is(err, thinappviewcore.ErrInvalidInboxRow):
		return "invalid_checkpoint"
	}
	var syntax *json.SyntaxError
	var value *json.UnmarshalTypeError
	if errors.As(err, &syntax) || errors.As(err, &value) {
		return "malformed_json"
	}
	var database *pgconn.PgError
	if errors.As(err, &database) {
		return "database_failed"
	}
	var network net.Error
	if errors.As(err, &network) {
		return "transport_failed"
	}
	return "restoration_failed"
}
