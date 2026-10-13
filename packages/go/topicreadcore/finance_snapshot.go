package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"log/slog"
	"time"
)

func (s *FinanceStore) snapshotCache() *decodedSnapshotCache[financecore.RankCandidate] {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.snapshots == nil {
		s.snapshots = &decodedSnapshotCache[financecore.RankCandidate]{}
	}
	return s.snapshots
}

func (s *FinanceStore) retained(ctx context.Context, id, scope, language, revision string, now time.Time) (*corpuscore.FinanceGeneration, error) {
	return s.loadDecodedSnapshot(ctx, id, false, scope, language, revision, now)
}

// Reuse is guarded by the same current database row and scopes as continuation.
func (s *FinanceStore) reusable(ctx context.Context, generation, scope, language, revision string, now time.Time) (*corpuscore.FinanceGeneration, error) {
	return s.loadDecodedSnapshot(ctx, generation, true, scope, language, revision, now)
}

func (s *FinanceStore) loadDecodedSnapshot(ctx context.Context, id string, reusable bool, scope, language, revision string, now time.Time) (*corpuscore.FinanceGeneration, error) {
	if !validUUID(id) {
		return nil, nil
	}
	metadata, candidates, err := s.snapshotCache().load(ctx, s.DB, "finance_personalized_snapshots", id, reusable, scope, language, revision, now)
	if err != nil || metadata == nil {
		return nil, err
	}
	return &corpuscore.FinanceGeneration{GenerationID: metadata.ID, GeneratedAt: metadata.GeneratedAt, ExpiresAt: metadata.ExpiresAt, Language: language, Candidates: candidates, Source: &metadata.Source}, nil
}

func (s *FinanceStore) persist(ctx context.Context, proposal, source corpuscore.FinanceGeneration, scope, revision string, now time.Time) (corpuscore.FinanceGeneration, error) {
	if !validUUID(proposal.GenerationID) || !validUUID(source.GenerationID) {
		return corpuscore.FinanceGeneration{}, ErrUnavailable
	}
	provenance := "ranked"
	if proposal.Source != nil {
		provenance = *proposal.Source
	}
	payload, err := corpuscore.MarshalHTTP(proposal.Candidates)
	if err != nil {
		return corpuscore.FinanceGeneration{}, err
	}
	if s.Remote != nil || provenance == "simplified_fallback" {
		s.purgeIfDue(ctx, now)
		raw, err := corpuscore.MarshalHTTP(source.Candidates)
		if err != nil {
			return corpuscore.FinanceGeneration{}, err
		}
		if _, err = s.DB.ExecContext(ctx, `INSERT INTO finance_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,serving_source)VALUES($1::uuid,$1::uuid,$2,'finance-v1',$3,$4,$5::jsonb,$6) ON CONFLICT(generation_id)DO NOTHING`, source.GenerationID, proposal.Language, proposal.GeneratedAt, proposal.ExpiresAt, raw, provenance); err != nil {
			return corpuscore.FinanceGeneration{}, err
		}
	}
	value := corpuscore.FinanceGeneration{Language: proposal.Language}
	var raw []byte
	var actualSource string
	err = s.DB.QueryRowContext(ctx, `INSERT INTO finance_personalized_snapshots(snapshot_id,source_generation_id,viewer_scope,language,preference_revision,generated_at,expires_at,payload,serving_source)VALUES($1::uuid,$2::uuid,$3,$4,$5,$6,$7,$8::jsonb,$9) ON CONFLICT(source_generation_id,viewer_scope,language,preference_revision)DO UPDATE SET viewer_scope=EXCLUDED.viewer_scope RETURNING snapshot_id::text,generated_at,expires_at,payload::text,serving_source`, proposal.GenerationID, source.GenerationID, scope, proposal.Language, revision, proposal.GeneratedAt, proposal.ExpiresAt, payload, provenance).Scan(&value.GenerationID, &value.GeneratedAt, &value.ExpiresAt, &raw, &actualSource)
	if err != nil {
		return value, err
	}
	value.Source = &actualSource
	err = corpuscore.DecodeContract(raw, &value.Candidates)
	return value, err
}
func (s *FinanceStore) purgeIfDue(ctx context.Context, now time.Time) {
	s.mu.Lock()
	if !s.lastRetention.IsZero() && now.Sub(s.lastRetention) < time.Minute {
		s.mu.Unlock()
		return
	}
	s.lastRetention = now
	s.mu.Unlock()
	tx, err := s.DB.BeginTx(ctx, nil)
	if err == nil {
		defer tx.Rollback()
		_, err = tx.ExecContext(ctx, `SET LOCAL lock_timeout='500ms'`)
		if err == nil {
			_, err = tx.ExecContext(ctx, `SET LOCAL statement_timeout='5s'`)
		}
		if err == nil {
			_, err = tx.ExecContext(ctx, `WITH expired AS(SELECT generation_id FROM finance_generations WHERE expires_at<=$1 ORDER BY expires_at LIMIT 100 FOR UPDATE SKIP LOCKED)DELETE FROM finance_generations generation USING expired WHERE generation.generation_id=expired.generation_id`, now)
		}
		if err == nil {
			err = tx.Commit()
		}
	}
	if err != nil {
		slog.Warn("Finance snapshot retention maintenance unavailable")
	}
}
