package topicreadcore

import (
	"errors"
	"fmt"
)

var (
	ErrUnavailable           = errors.New("discovery unavailable")
	ErrInvalidCursor         = errors.New("invalid discovery cursor")
	ErrCursorExpired         = errors.New("discovery cursor expired")
	ErrModerationUnavailable = errors.New("viewer moderation unavailable")
	// Missing capabilities are recoverable by one client proof-preparation retry.
	// Keep the moderation classification so existing fail-closed callers remain safe.
	ErrUpstreamProofRequired = fmt.Errorf("%w: upstream proof required", ErrModerationUnavailable)
	ErrItemNotFound          = errors.New("discovery item not found")
)
