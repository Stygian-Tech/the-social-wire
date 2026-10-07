package operationsapi

import "errors"

var (
	ErrNotFound             = errors.New("Operations record not found")
	ErrVersionConflict      = errors.New("Operations version changed")
	ErrInvalidTransition    = errors.New("invalid Operations state transition")
	ErrIdempotencyConflict  = errors.New("Operations idempotency conflict")
	ErrOverlappingBackfill  = errors.New("overlapping Operations backfill")
	ErrBackfillScopeChanged = errors.New("Operations backfill scope changed")
	ErrBackfillFingerprint  = errors.New("invalid Operations backfill fingerprint")
	ErrLeaseConflict        = errors.New("Operations lease ownership changed")
	ErrInvalidProgress      = errors.New("invalid Operations backfill progress")
	ErrEnvironmentMismatch  = errors.New("Operations environment scope does not match")
)
