package wireworkercore

import (
	"context"
	"time"
)

func (s *PostgresGenerationStore) DeleteExpired(ctx context.Context, at time.Time, batchSize int) error {
	batchSize = max(1, min(batchSize, 5000))
	generationLimit := min(batchSize, 4)
	start := time.Now()
	for range 16 {
		result, err := s.DB.ExecContext(ctx, `DELETE FROM wire_rank_generations WHERE generation_id IN(SELECT generation_id FROM wire_rank_generations WHERE expires_at<=$1 AND is_active=FALSE ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`, at, generationLimit)
		if err != nil {
			return err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if count < int64(generationLimit) || time.Since(start) >= 15*time.Second {
			break
		}
	}
	// Statements commit separately, preserving bounded retention transactions.
	for _, query := range []string{
		`DELETE FROM wire_signal_events WHERE(occurred_at,id)IN(SELECT occurred_at,id FROM wire_signal_events WHERE expires_at<=$1 ORDER BY expires_at,occurred_at,id LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_follow_edges WHERE(follower_key_hash,followee_key_hash)IN(SELECT follower_key_hash,followee_key_hash FROM wire_follow_edges WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_actor_communities WHERE actor_key_hash IN(SELECT actor_key_hash FROM wire_actor_communities WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_active_actors WHERE actor_key_hash IN(SELECT actor_key_hash FROM wire_active_actors WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_publications WHERE publication_uri IN(SELECT publication_uri FROM wire_publications WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_item_aliases WHERE alias_key IN(SELECT alias_key FROM wire_item_aliases WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_labels WHERE(canonical_key,label_key,source)IN(SELECT canonical_key,label_key,source FROM wire_labels WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
		`DELETE FROM wire_items WHERE canonical_key IN(SELECT canonical_key FROM wire_items WHERE expires_at<=$1 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED)`,
	} {
		if _, err := s.DB.ExecContext(ctx, query, at, batchSize); err != nil {
			return err
		}
	}
	return nil
}
