package thinappviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

type ContentStore struct{ DB *sql.DB }

func (s ContentStore) Upsert(ctx context.Context, item IndexedContentItem) error {
	render, err := json.Marshal(item.Render)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9)
 ON CONFLICT(uri) DO UPDATE SET cid=EXCLUDED.cid,author_did=EXCLUDED.author_did,collection=EXCLUDED.collection,created_at=EXCLUDED.created_at,indexed_at=EXCLUDED.indexed_at,publication_site=EXCLUDED.publication_site,render_json=EXCLUDED.render_json,expires_at=EXCLUDED.expires_at
 WHERE (content_items.cid,content_items.author_did,content_items.collection,content_items.created_at,content_items.publication_site,content_items.render_json,content_items.expires_at)
 IS DISTINCT FROM (EXCLUDED.cid,EXCLUDED.author_did,EXCLUDED.collection,EXCLUDED.created_at,EXCLUDED.publication_site,EXCLUDED.render_json,EXCLUDED.expires_at)`, item.URI, item.CID, item.AuthorDID, item.Collection, item.CreatedAt, item.IndexedAt, item.PublicationSite, string(render), item.ExpiresAt)
	return err
}
func (s ContentStore) Delete(ctx context.Context, uri string) error {
	_, err := s.DB.ExecContext(ctx, "DELETE FROM content_items WHERE uri=$1", uri)
	return err
}
func (s ContentStore) DeleteAuthor(ctx context.Context, did string) (int64, error) {
	result, err := s.DB.ExecContext(ctx, "DELETE FROM content_items WHERE author_did=$1", did)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// Recovery excludes records observed after recovery began, preserving concurrent
// Jetstream updates while pruning records absent from the completed PDS snapshot.
func (s ContentStore) DeleteMissingAuthorRecords(ctx context.Context, did string, seenURIs []string, before time.Time) (int64, error) {
	if seenURIs == nil {
		seenURIs = []string{}
	}
	result, err := s.DB.ExecContext(ctx, "DELETE FROM content_items WHERE author_did=$1 AND indexed_at<=$2 AND NOT(uri=ANY($3::text[]))", did, before, seenURIs)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
func (s ContentStore) Exists(ctx context.Context, uri string) (bool, error) {
	var found bool
	err := s.DB.QueryRowContext(ctx, "SELECT EXISTS(SELECT 1 FROM content_items WHERE uri=$1)", uri).Scan(&found)
	return found, err
}
