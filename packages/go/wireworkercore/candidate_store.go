// Package wireworkercore implements reusable Wire background ranking components.
package wireworkercore

// Loads canonical-schema candidate snapshots and discovers serving language buckets. The
// optional global metadata projection uses a read-only transaction with local planner
// settings; malformed topics become empty and unknown enum values fail conservatively.

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// PostgresGenerationStore uses the canonical PostgreSQL schema; active publication
// requires Authority from a live role lease.
type PostgresGenerationStore struct {
	DB                               *sql.DB
	Authority                        *operationscore.RoleLeaseAuthority
	GlobalCandidateProjectionEnabled bool
}

// Ping checks connectivity before a cycle attempts maintenance or ranking.
func (store *PostgresGenerationStore) Ping(ctx context.Context) error {
	return store.DB.PingContext(ctx)
}

// EligibleLanguageBuckets returns at most twelve non-global buckets meeting configured
// quality/signal and candidate-count floors.
func (store *PostgresGenerationStore) EligibleLanguageBuckets(ctx context.Context, limit, minimumCandidates int, ranking wirecore.RankingConfig, at time.Time) ([]string, error) {
	rows, err := store.DB.QueryContext(ctx, eligibleLanguagesQuery, at, at.Add(-time.Duration(ranking.MaximumCandidateAge*float64(time.Second))), at.Add(-72*time.Hour), ranking.Version == wirecore.ExternalSignalVersion, ranking.MinimumSourceConfidence, ranking.BackfillMinimumHighIntentActors, ranking.BackfillMinimumRecommendations, ranking.StandardSiteMinimumSourceConfidence, ranking.StandardSiteMinimumHighIntentActors, minimumCandidates, max(0, min(limit, 12)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []string{}
	for rows.Next() {
		var language string
		if err := rows.Scan(&language); err != nil {
			return nil, err
		}
		result = append(result, language)
	}
	return result, rows.Err()
}

// LoadCandidates loads a bounded baseline or external-rollup snapshot, optionally using
// the equivalent global metadata projection.
func (store *PostgresGenerationStore) LoadCandidates(ctx context.Context, language string, limit int, ranking wirecore.RankingConfig, at time.Time) ([]wirecore.Candidate, error) {
	query := candidateQuery
	var tx *sql.Tx
	projected := store.GlobalCandidateProjectionEnabled && language == "und"
	var rows *sql.Rows
	var err error
	args := []any{ranking.Version == wirecore.ExternalSignalVersion, at, at.Add(-72 * time.Hour), language, limit}
	if projected {
		query = projectedCandidateQuery
		tx, err = store.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
		if err != nil {
			return nil, err
		}
		defer tx.Rollback()
		for _, setting := range []string{"SET LOCAL work_mem = '64MB'", "SET LOCAL max_parallel_workers_per_gather = 0"} {
			if _, err := tx.ExecContext(ctx, setting); err != nil {
				return nil, err
			}
		}
		rows, err = tx.QueryContext(ctx, query, args...)
	} else {
		rows, err = store.DB.QueryContext(ctx, query, args...)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []wirecore.Candidate{}
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var candidate wirecore.Candidate
		var topics, target, commercial string
		err := rows.Scan(&candidate.CanonicalKey, &candidate.CanonicalURL, &candidate.RepresentativeURI, &candidate.SourceDomain, &candidate.PublicationID, &candidate.AuthorKey, &topics, &candidate.PublishedAt, &candidate.FirstSeenAt, &candidate.LastSignalAt, &candidate.SourceConfidence, &candidate.IsStandardSite, &candidate.HasUsableOpenGraphMetadata, &target, &commercial, &candidate.CommercialScore, &candidate.DistinctActors1h, &candidate.DistinctActors24h, &candidate.DistinctActors7d, &candidate.Signals1h, &candidate.Signals24h, &candidate.Signals7d, &candidate.Communities24h, &candidate.PrimaryCommunityKey, &candidate.Recommendations24h, &candidate.PositiveFeedback24h, &candidate.NegativeFeedback24h, &candidate.Shares1h, &candidate.Shares24h, &candidate.DistinctLikes24h, &candidate.Likes1h, &candidate.Likes24h, &candidate.DistinctReposts24h, &candidate.Reposts1h, &candidate.Reposts24h, &candidate.HasUsableThumbnail)
		if err != nil {
			return nil, err
		}
		candidate.TopicKeys = []string{}
		if err := json.Unmarshal([]byte(topics), &candidate.TopicKeys); err != nil {
			candidate.TopicKeys = []string{}
		}
		candidate.TargetKind = wirecore.TargetKind(target)
		switch candidate.TargetKind {
		case wirecore.ExternalArticle, wirecore.StandardSiteDocument, wirecore.SocialPost, wirecore.ProfileOrFeed, wirecore.CommerceOrAd, wirecore.OperationalStatus, wirecore.Unsupported:
		default:
			candidate.TargetKind = wirecore.Unsupported
		}
		candidate.CommercialClass = wirecore.CommercialClass(commercial)
		switch candidate.CommercialClass {
		case wirecore.Normal, wirecore.Limited, wirecore.ProbableAd:
		default:
			candidate.CommercialClass = wirecore.ProbableAd
		}
		result = append(result, candidate)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if tx != nil {
		if err := tx.Commit(); err != nil {
			return nil, err
		}
	}
	return result, nil
}
