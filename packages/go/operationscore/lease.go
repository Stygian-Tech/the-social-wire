// Package operationscore implements the shared control-plane authority contracts.
package operationscore

// Defines role ownership as environment, role, owner ID, and monotonically changing
// fencing token. Configuration reserves five seconds of lease safety margin; ownership
// work must carry this authority into its publication transaction.

import (
	"context"
	"errors"
	"time"
	"unicode/utf8"
)

var (
	ErrLeaseConflict    = errors.New("role lease conflict")
	ErrInvalidProgress  = errors.New("invalid lease progress")
	ErrAuthorityExpired = errors.New("role authority expired")
)

// RoleLeaseAuthority identifies one ownership epoch; the token must accompany every
// protected publication.
type RoleLeaseAuthority struct {
	Environment  string `json:"environment"`
	Role         string `json:"role"`
	OwnerID      string `json:"ownerID"`
	FencingToken int64  `json:"fencingToken"`
}

// FencedRoleLease adds database acquisition, expiry, and update timestamps to an
// authority.
type FencedRoleLease struct {
	RoleLeaseAuthority
	AcquiredAt time.Time `json:"acquiredAt"`
	ExpiresAt  time.Time `json:"expiresAt"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

// ValidateRoleIdentity requires nonempty role/owner identifiers within 128/255 Unicode
// code points.
func ValidateRoleIdentity(role, owner string) error {
	if role == "" || utf8.RuneCountInString(role) > 128 || owner == "" || utf8.RuneCountInString(owner) > 255 {
		return ErrInvalidProgress
	}
	return nil
}

// RoleLeaseStore provides distributed ownership; a nil Acquire result means standby rather
// than failure.
type RoleLeaseStore interface {
	Acquire(context.Context, string, string, time.Duration) (*FencedRoleLease, error)
	Renew(context.Context, RoleLeaseAuthority, time.Duration) (FencedRoleLease, error)
	Release(context.Context, RoleLeaseAuthority) error
	Validate(context.Context, RoleLeaseAuthority) error
}

// SupervisorConfig sets lease duration, renewal cadence, and standby retry with a five-
// second safety margin.
type SupervisorConfig struct {
	Role, OwnerID                                      string
	LeaseDuration, RenewInterval, StandbyRetryInterval time.Duration
}

// Validate requires valid role/owner IDs and positive retry/renewal durations,
// leaving five seconds between renewal cadence and lease expiry.
func (config SupervisorConfig) Validate() error {
	if err := ValidateRoleIdentity(config.Role, config.OwnerID); err != nil {
		return err
	}
	if config.LeaseDuration <= 5*time.Second || config.RenewInterval <= 0 || config.RenewInterval >= config.LeaseDuration-5*time.Second || config.StandbyRetryInterval <= 0 {
		return ErrInvalidProgress
	}
	return nil
}

// DefaultSupervisorConfig uses a 30-second lease, ten-second renewal, and five-second
// standby retry.
func DefaultSupervisorConfig(role, owner string) SupervisorConfig {
	return SupervisorConfig{role, owner, 30 * time.Second, 10 * time.Second, 5 * time.Second}
}

// LeaseEvent reports a supervisor phase, authority, and associated error to a nonblocking
// observer.
type LeaseEvent struct {
	Phase     string
	Authority RoleLeaseAuthority
	Err       error
}
