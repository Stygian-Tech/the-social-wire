package publications

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func logEnrollmentFailure(phase string, started time.Time, authors, feeds, indexed int, err, requestErr error) {
	if err == nil {
		return
	}
	failures := thinappviewcore.EnrollmentFailureCounts(err)
	count := 0
	for _, failure := range failures {
		count += failure.Count
	}
	// Never pass err, the request, viewer identity or source lists to a logger.
	slog.Error("Enrollment phase failed", "phase", phase, "duration_ms", time.Since(started).Milliseconds(), "requested_authors", authors, "requested_feeds", feeds, "indexed", indexed, "request_canceled", errors.Is(requestErr, context.Canceled), "request_timed_out", errors.Is(requestErr, context.DeadlineExceeded), "failure_count", count, "failures", failures)
}
