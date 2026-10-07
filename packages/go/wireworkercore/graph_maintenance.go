package wireworkercore

import (
	"context"
	"database/sql"
	"time"
)

// GraphMaintenance preserves the bounded public actor corpus and the six-round
// deterministic label propagation used by Wire ranking.
type GraphMaintenance struct{ DB *sql.DB }

func (s GraphMaintenance) Prune(ctx context.Context, at time.Time) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, query := range []string{
		`DELETE FROM wire_active_actors actor WHERE actor.expires_at<=$1 OR actor.actor_key_hash IN(SELECT actor_key_hash FROM wire_active_actors WHERE expires_at>$1 ORDER BY last_active_at DESC,actor_key_hash OFFSET 250000)`,
		`DELETE FROM wire_follow_edges edge WHERE edge.expires_at<=$1 OR NOT EXISTS(SELECT 1 FROM wire_active_actors actor WHERE actor.actor_key_hash=edge.follower_key_hash) OR NOT EXISTS(SELECT 1 FROM wire_active_actors actor WHERE actor.actor_key_hash=edge.followee_key_hash)`,
		`DELETE FROM wire_article_feedback WHERE expires_at<=$1`,
	} {
		if _, err = tx.ExecContext(ctx, query, at); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s GraphMaintenance) RefreshCommunities(ctx context.Context, at time.Time) (time.Time, error) {
	var last sql.NullTime
	if err := s.DB.QueryRowContext(ctx, `SELECT MAX(assigned_at) FROM wire_actor_communities`).Scan(&last); err != nil {
		return time.Time{}, err
	}
	if last.Valid && at.Sub(last.Time) < 6*time.Hour {
		return last.Time.Add(6 * time.Hour), nil
	}
	if err := s.Prune(ctx, at); err != nil {
		return time.Time{}, err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return time.Time{}, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `CREATE TEMP TABLE wire_cluster_work(actor_key_hash text PRIMARY KEY,label text NOT NULL)ON COMMIT DROP`); err != nil {
		return time.Time{}, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO wire_cluster_work SELECT actor_key_hash,actor_key_hash FROM wire_active_actors WHERE expires_at>$1`, at); err != nil {
		return time.Time{}, err
	}
	for i := 0; i < 6; i++ {
		if _, err = tx.ExecContext(ctx, `UPDATE wire_cluster_work current SET label=LEAST(current.label,neighbor.minimum_label) FROM(SELECT actor_key_hash,MIN(label)AS minimum_label FROM(SELECT edge.follower_key_hash AS actor_key_hash,target.label FROM wire_follow_edges edge JOIN wire_cluster_work target ON target.actor_key_hash=edge.followee_key_hash UNION ALL SELECT edge.followee_key_hash AS actor_key_hash,source.label FROM wire_follow_edges edge JOIN wire_cluster_work source ON source.actor_key_hash=edge.follower_key_hash)adjacent GROUP BY actor_key_hash)neighbor WHERE current.actor_key_hash=neighbor.actor_key_hash AND current.label>neighbor.minimum_label`); err != nil {
			return time.Time{}, err
		}
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_actor_communities`); err != nil {
		return time.Time{}, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO wire_actor_communities(actor_key_hash,community_key_hash,algorithm_version,assigned_at,expires_at) SELECT work.actor_key_hash,work.label,'wire-community-v1',$1,$2 FROM wire_cluster_work work JOIN(SELECT label FROM wire_cluster_work GROUP BY label HAVING COUNT(*)>=3)qualifying ON qualifying.label=work.label`, at, at.Add(7*24*time.Hour)); err != nil {
		return time.Time{}, err
	}
	for _, query := range []string{
		`UPDATE wire_signal_events signal SET community_key_hash=community.community_key_hash FROM wire_actor_communities community WHERE community.actor_key_hash=signal.actor_key_hash AND signal.community_key_hash IS DISTINCT FROM community.community_key_hash`,
		`UPDATE wire_signal_events signal SET community_key_hash=NULL WHERE signal.community_key_hash IS NOT NULL AND NOT EXISTS(SELECT 1 FROM wire_actor_communities community WHERE community.actor_key_hash=signal.actor_key_hash)`,
	} {
		if _, err = tx.ExecContext(ctx, query); err != nil {
			return time.Time{}, err
		}
	}
	if err = tx.Commit(); err != nil {
		return time.Time{}, err
	}
	return at.Add(6 * time.Hour), nil
}
