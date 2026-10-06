// Package operationscore implements the shared control-plane authority contracts.
package operationscore

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

type RoleLeaseAuthority struct {
	Environment  string `json:"environment"`
	Role         string `json:"role"`
	OwnerID      string `json:"ownerID"`
	FencingToken int64  `json:"fencingToken"`
}
type FencedRoleLease struct {
	RoleLeaseAuthority
	AcquiredAt time.Time `json:"acquiredAt"`
	ExpiresAt  time.Time `json:"expiresAt"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

func ValidateRoleIdentity(role, owner string) error {
	if role == "" || utf8.RuneCountInString(role) > 128 || owner == "" || utf8.RuneCountInString(owner) > 255 {
		return ErrInvalidProgress
	}
	return nil
}

type RoleLeaseStore interface {
	Acquire(context.Context, string, string, time.Duration) (*FencedRoleLease, error)
	Renew(context.Context, RoleLeaseAuthority, time.Duration) (FencedRoleLease, error)
	Release(context.Context, RoleLeaseAuthority) error
	Validate(context.Context, RoleLeaseAuthority) error
}
type SupervisorConfig struct {
	Role, OwnerID                                      string
	LeaseDuration, RenewInterval, StandbyRetryInterval time.Duration
}

func (c SupervisorConfig) Validate() error {
	if err := ValidateRoleIdentity(c.Role, c.OwnerID); err != nil {
		return err
	}
	if c.LeaseDuration <= 5*time.Second || c.RenewInterval <= 0 || c.RenewInterval >= c.LeaseDuration-5*time.Second || c.StandbyRetryInterval <= 0 {
		return ErrInvalidProgress
	}
	return nil
}
func DefaultSupervisorConfig(role, owner string) SupervisorConfig {
	return SupervisorConfig{role, owner, 30 * time.Second, 10 * time.Second, 5 * time.Second}
}

type LeaseEvent struct {
	Phase     string
	Authority RoleLeaseAuthority
	Err       error
}
