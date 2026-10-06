package wireworkercore

import (
	"context"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type GenerationCommit struct {
	GenerationID, FeedKey, LanguageBucket, ConfigVersion string
	GeneratedAt, ExpiresAt                               time.Time
	Activate                                             bool
	Result                                               wirecore.RankingResult
}
type GenerationStore interface {
	Ping(context.Context) error
	EligibleLanguageBuckets(context.Context, int, int, wirecore.RankingConfig, time.Time) ([]string, error)
	LoadCandidates(context.Context, string, int, wirecore.RankingConfig, time.Time) ([]wirecore.Candidate, error)
	Commit(context.Context, GenerationCommit) error
	DeleteExpired(context.Context, time.Time, int) error
}
