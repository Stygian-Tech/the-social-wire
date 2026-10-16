package service

import (
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

// Archive transport success is not durable progress. Only an independently
// committed job cursor resets retry pressure, including a committed burst prefix.
type recoveryRetryBackoff struct{ minimum, maximum, current time.Duration }

func newRecoveryRetryBackoff(minimum, maximum time.Duration) recoveryRetryBackoff {
	if minimum <= 0 {
		minimum = 250 * time.Millisecond
	}
	if maximum < minimum {
		maximum = minimum
	}
	return recoveryRetryBackoff{minimum: minimum, maximum: maximum}
}
func (b *recoveryRetryBackoff) next(progressed bool) time.Duration {
	if progressed || b.current == 0 {
		b.current = b.minimum
	} else {
		if b.current >= b.maximum/2 {
			b.current = b.maximum
		} else {
			b.current *= 2
		}
	}
	return b.current
}
func recoveryCursorProgressed(previous *uint64, checkpoint *ingest.Checkpoint) bool {
	return checkpoint != nil && checkpoint.LastStagedSeq != nil && (previous == nil || *checkpoint.LastStagedSeq > *previous)
}
