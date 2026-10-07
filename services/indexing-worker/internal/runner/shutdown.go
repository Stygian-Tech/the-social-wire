package runner

import (
	"context"
	"errors"
)

// IsCancellation distinguishes a normal joined cancellation from cancellation
// accompanied by a real shutdown failure. errors.Is alone masks joined errors.
func IsCancellation(err error) bool {
	if err == nil {
		return false
	}
	if joined, ok := err.(interface{ Unwrap() []error }); ok {
		children := joined.Unwrap()
		if len(children) == 0 {
			return false
		}
		for _, child := range children {
			if !IsCancellation(child) {
				return false
			}
		}
		return true
	}
	return errors.Is(err, context.Canceled)
}
