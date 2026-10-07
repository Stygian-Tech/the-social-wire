package operationsapi

import (
	"context"
	"errors"
	"strconv"
	"time"
)

type MutationAudit struct {
	OperatorDID, RequestID, Action, TargetType string
	TargetID, IdempotencyKey, Note             *string
	ExpectedVersion                            *int
	Before, After                              map[string]string
	Outcome                                    string
	OccurredAt                                 time.Time
}

// Success auditing belongs to the same SQL transaction as the mutation.
// A scope is request-owned; rejected and failed attempts are recorded here.
type MutationAuditScope struct{ Audit MutationAudit }

func (s *MutationAuditScope) Failure(err error, status int, at time.Time) MutationAudit {
	audit := s.Audit
	audit.After = map[string]string{"error": ErrorCategory(err), "httpStatus": strconv.Itoa(status)}
	audit.Outcome = "failed"
	if status < 500 {
		audit.Outcome = "rejected"
	}
	audit.OccurredAt = at
	return audit
}

var ErrMutationAuditUnavailable = errors.New("mutation outcome could not be durably audited")

func AuditedMutation[T any](ctx context.Context, scope *MutationAuditScope, record func(context.Context, MutationAudit) error, operation func() (T, error), status func(error) int) (T, error) {
	result, err := operation()
	if err == nil {
		return result, nil
	}
	// Request cancellation must not erase the audit of an already attempted mutation.
	auditCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if auditErr := record(auditCtx, scope.Failure(err, status(err), time.Now())); auditErr != nil {
		var zero T
		return zero, ErrMutationAuditUnavailable
	}
	return result, err
}

func NewMutationAuditScope(operatorDID, requestID, action, targetType string, targetID, idempotencyHeader *string) *MutationAuditScope {
	var key *string
	if idempotencyHeader != nil {
		value := boundedText(*idempotencyHeader, 128)
		key = &value
	}
	return &MutationAuditScope{Audit: MutationAudit{OperatorDID: operatorDID, RequestID: requestID, Action: action, TargetType: targetType, TargetID: targetID, IdempotencyKey: key, Before: map[string]string{}}}
}
func (s *MutationAuditScope) Update(action, idempotencyKey *string, expectedVersion *int, note *string) {
	if action != nil {
		s.Audit.Action = *action
	}
	if idempotencyKey != nil {
		value := boundedText(*idempotencyKey, 128)
		s.Audit.IdempotencyKey = &value
	}
	s.Audit.ExpectedVersion = expectedVersion
	s.Audit.Note = nil
	if note != nil {
		value := boundedText(*note, 280)
		s.Audit.Note = &value
	}
}
