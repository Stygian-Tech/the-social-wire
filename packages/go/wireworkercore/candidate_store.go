// Package wireworkercore implements reusable Wire background ranking components.
package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type PostgresGenerationStore struct {
	DB                               *sql.DB
	Authority                        *operationscore.RoleLeaseAuthority
	GlobalCandidateProjectionEnabled bool
}

func (s *PostgresGenerationStore) Ping(ctx context.Context) error { return s.DB.PingContext(ctx) }
func (s *PostgresGenerationStore) EligibleLanguageBuckets(ctx context.Context, limit, minimumCandidates int, ranking wirecore.RankingConfig, at time.Time) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, eligibleLanguagesQuery, at, at.Add(-time.Duration(ranking.MaximumCandidateAge*float64(time.Second))), at.Add(-72*time.Hour), ranking.Version == wirecore.ExternalSignalVersion, ranking.MinimumSourceConfidence, ranking.BackfillMinimumHighIntentActors, ranking.BackfillMinimumRecommendations, ranking.StandardSiteMinimumSourceConfidence, ranking.StandardSiteMinimumHighIntentActors, minimumCandidates, max(0, min(limit, 12)))
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
func (s *PostgresGenerationStore) LoadCandidates(ctx context.Context, language string, limit int, ranking wirecore.RankingConfig, at time.Time) ([]wirecore.Candidate, error) {
	query := candidateQuery
	var tx *sql.Tx
	projected := s.GlobalCandidateProjectionEnabled && language == "und"
	var rows *sql.Rows
	var err error
	args := []any{ranking.Version == wirecore.ExternalSignalVersion, at, at.Add(-72 * time.Hour), language, limit}
	if projected {
		query = projectedCandidateQuery
		tx, err = s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
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
		rows, err = s.DB.QueryContext(ctx, query, args...)
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
		var c wirecore.Candidate
		var topics, target, commercial string
		err := rows.Scan(&c.CanonicalKey, &c.CanonicalURL, &c.RepresentativeURI, &c.SourceDomain, &c.PublicationID, &c.AuthorKey, &topics, &c.PublishedAt, &c.FirstSeenAt, &c.LastSignalAt, &c.SourceConfidence, &c.IsStandardSite, &c.HasUsableOpenGraphMetadata, &target, &commercial, &c.CommercialScore, &c.DistinctActors1h, &c.DistinctActors24h, &c.DistinctActors7d, &c.Signals1h, &c.Signals24h, &c.Signals7d, &c.Communities24h, &c.PrimaryCommunityKey, &c.Recommendations24h, &c.PositiveFeedback24h, &c.NegativeFeedback24h, &c.Shares1h, &c.Shares24h, &c.DistinctLikes24h, &c.Likes1h, &c.Likes24h, &c.DistinctReposts24h, &c.Reposts1h, &c.Reposts24h, &c.HasUsableThumbnail)
		if err != nil {
			return nil, err
		}
		c.TopicKeys = []string{}
		if err := json.Unmarshal([]byte(topics), &c.TopicKeys); err != nil {
			c.TopicKeys = []string{}
		}
		c.TargetKind = wirecore.TargetKind(target)
		switch c.TargetKind {
		case wirecore.ExternalArticle, wirecore.StandardSiteDocument, wirecore.SocialPost, wirecore.ProfileOrFeed, wirecore.CommerceOrAd, wirecore.OperationalStatus, wirecore.Unsupported:
		default:
			c.TargetKind = wirecore.Unsupported
		}
		c.CommercialClass = wirecore.CommercialClass(commercial)
		switch c.CommercialClass {
		case wirecore.Normal, wirecore.Limited, wirecore.ProbableAd:
		default:
			c.CommercialClass = wirecore.ProbableAd
		}
		result = append(result, c)
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
