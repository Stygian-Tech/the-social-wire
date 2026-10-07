package wireworkercore

// Defines the immutable publication request and store boundary needed by ranking cycles.
// Store implementations own transactional publication, while hosts supply authority, label
// refresh, inbox application, and runtime configuration.

import (
	"context"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// GenerationCommit contains one ranked generation’s identity, expiry, diagnostics, and
// activation intent.
type GenerationCommit struct {
	GenerationID, FeedKey, LanguageBucket, ConfigVersion string
	GeneratedAt, ExpiresAt                               time.Time
	Activate                                             bool
	Result                                               wirecore.RankingResult
}

// GenerationStore is the connectivity, candidate loading, publication, and bounded
// retention boundary for Cycle.
type GenerationStore interface {
	Ping(context.Context) error
	EligibleLanguageBuckets(context.Context, int, int, wirecore.RankingConfig, time.Time) ([]string, error)
	LoadCandidates(context.Context, string, int, wirecore.RankingConfig, time.Time) ([]wirecore.Candidate, error)
	Commit(context.Context, GenerationCommit) error
	DeleteExpired(context.Context, time.Time, int) error
}
