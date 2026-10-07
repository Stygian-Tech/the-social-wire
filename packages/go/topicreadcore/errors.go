package topicreadcore

import (
	"errors"
)

var (
	ErrUnavailable           = errors.New("discovery unavailable")
	ErrInvalidCursor         = errors.New("invalid discovery cursor")
	ErrCursorExpired         = errors.New("discovery cursor expired")
	ErrModerationUnavailable = errors.New("viewer moderation unavailable")
	ErrItemNotFound          = errors.New("discovery item not found")
)
