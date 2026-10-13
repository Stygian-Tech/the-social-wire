package topicreadcore

import (
	"context"
	"database/sql"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

// Reuse the same in-process authority that hydrates current items. A different
// database handle or a remote adapter must retain its existing source path.
func localSourceStore(wire *WireStore, db *sql.DB) *corpuscore.PostgreSQLStore {
	if wire == nil || db == nil {
		return nil
	}
	store, ok := wire.Corpus.(*corpuscore.PostgreSQLStore)
	if !ok || store == nil || store.DB != db {
		return nil
	}
	return store
}

// Serving provenance is local AppView metadata, deliberately outside the
// internal transport contract. Keep the existing fallback/degraded flags while
// selecting only a current generation identity rather than its full payload.
func localSourceProvenance(ctx context.Context, db *sql.DB, sports bool, id string) (*string, error) {
	query := `SELECT serving_source FROM finance_generations WHERE generation_id=$1::uuid`
	if sports {
		query = `SELECT serving_source FROM sports_generations WHERE generation_id=$1::uuid`
	}
	var provenance string
	if err := db.QueryRowContext(ctx, query, id).Scan(&provenance); err != nil {
		return nil, err
	}
	return &provenance, nil
}
