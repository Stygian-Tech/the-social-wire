package corpuscore

import (
	"context"
	"time"
)

const MaximumBatchItems = 100
const BatchItemsPath = "/xrpc/app.thesocialwire.corpus.getItems"

type ItemsRequest struct {
	ItemIDs []string `json:"itemIds"`
}
type ItemsResponse struct {
	Items map[string]Item `json:"items"`
}

// BatchItemStore returns only currently eligible items. Missing IDs are omitted;
// callers restore request order and never substitute stale snapshot bodies.
type BatchItemStore interface {
	Items(context.Context, []string, time.Time) ([]Item, error)
}

var _ BatchItemStore = (*PostgreSQLStore)(nil)
var _ BatchItemStore = (*RemoteStore)(nil)

func ValidItemIDs(ids []string) bool {
	if len(ids) == 0 || len(ids) > MaximumBatchItems {
		return false
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || len(id) > 128 || seen[id] {
			return false
		}
		seen[id] = true
	}
	return true
}

// LoadItems keeps test/legacy store adapters compatible. Both production stores
// implement BatchItemStore, so production pages use one corpus request per batch.
func LoadItems(ctx context.Context, store Store, ids []string, now time.Time) ([]Item, error) {
	if !ValidItemIDs(ids) {
		return nil, ErrContractMismatch
	}
	if batch, ok := store.(BatchItemStore); ok {
		return batch.Items(ctx, ids, now)
	}
	items := []Item{}
	for _, id := range ids {
		item, err := store.Item(ctx, id, now)
		if err != nil {
			return nil, err
		}
		if item != nil {
			items = append(items, *item)
		}
	}
	return items, nil
}

func (s *PostgreSQLStore) Items(ctx context.Context, ids []string, now time.Time) ([]Item, error) {
	if !ValidItemIDs(ids) {
		return nil, ErrContractMismatch
	}
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return nil, err
	}
	// The security-barrier view rechecks eligibility and labels on every batch.
	rows, err := s.query(ctx, `SELECT canonical_key,canonical_url,representative_uri,title,summary,published_at,thumbnail_url,source_name,source_domain,publication_id,author_name,provenance::text,author_key,publication_key,publication_homepage_url,publication_icon_url FROM wire_serving.items WHERE canonical_key=ANY($1::text[])`, ids)
	if err != nil {
		return nil, err
	}
	items := make([]Item, 0, len(rows))
	for _, row := range rows {
		item := Item{decodeItem(row, 0, "[]", 13), row.OptionalString(12)}
		if row.err != nil {
			return nil, row.err
		}
		items = append(items, item)
	}
	return items, nil
}

func (s *RemoteStore) Items(ctx context.Context, ids []string, _ time.Time) ([]Item, error) {
	if !ValidItemIDs(ids) {
		return nil, ErrContractMismatch
	}
	body, err := MarshalHTTP(ItemsRequest{ids})
	if err != nil {
		return nil, err
	}
	result, err := remoteDecode[ItemsResponse](ctx, s, "POST", BatchItemsPath, body)
	if err != nil {
		return nil, err
	}
	wanted := map[string]bool{}
	for _, id := range ids {
		wanted[id] = true
	}
	seen := map[string]bool{}
	if result.Items == nil || len(result.Items) > len(ids) {
		return nil, ErrContractMismatch
	}
	items := make([]Item, 0, len(result.Items))
	for key, item := range result.Items {
		id := item.Item.ItemID
		if key != id || !wanted[id] || seen[id] {
			return nil, ErrContractMismatch
		}
		seen[id] = true
		items = append(items, item)
	}
	return items, nil
}
