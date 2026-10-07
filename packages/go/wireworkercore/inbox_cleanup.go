package wireworkercore

import (
	"context"
	"encoding/json"
	"time"
)

func (s PostgresInboxClaims) DeleteTerminal(ctx context.Context, at time.Time, batchSize int) (int, error) {
	batchSize = max(1, min(batchSize, 20000))
	var environment any
	generations := "[]"
	if s.Scope != nil {
		environment = s.Scope.Environment
		data, _ := json.Marshal(s.Scope.Generations)
		generations = string(data)
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `DELETE FROM wire_ingestion_inbox WHERE(environment,source_generation,seq) IN(SELECT environment,source_generation,seq FROM wire_ingestion_inbox WHERE($1::text IS NULL OR(environment=$1 AND source_generation IN(SELECT jsonb_array_elements_text($2::jsonb)))) AND(status IN('applied','dead_letter') OR(status IN('deferred','superseded')AND EXISTS(SELECT 1 FROM wire_recommendation_journal journal WHERE journal.environment=wire_ingestion_inbox.environment AND journal.source_generation=wire_ingestion_inbox.source_generation AND journal.seq=wire_ingestion_inbox.seq)))AND expires_at<=$3 ORDER BY expires_at,environment,source_generation,seq FOR UPDATE SKIP LOCKED LIMIT $4) RETURNING environment`, environment, generations, at, batchSize)
	if err != nil {
		return 0, err
	}
	counts := map[string]int{}
	total := 0
	for rows.Next() {
		var value string
		if err = rows.Scan(&value); err != nil {
			rows.Close()
			return 0, err
		}
		counts[value]++
		total++
	}
	err = rows.Err()
	closeErr := rows.Close()
	if err != nil {
		return 0, err
	}
	if closeErr != nil {
		return 0, closeErr
	}
	for environment, count := range counts {
		if _, err = tx.ExecContext(ctx, `UPDATE wire_ingestion_admission SET retained_rows=GREATEST(0,retained_rows-$1),updated_at=$2 WHERE environment=$3`, count, at, environment); err != nil {
			return 0, err
		}
	}
	if err = tx.Commit(); err != nil {
		return 0, err
	}
	return total, nil
}
