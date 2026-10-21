package publicationcore

import (
	"context"
	"sync"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

// refreshMetadata is owned by one manual refresh. It carries fresh discovery
// records into scope construction and shares identical page reads among workers.
// It is never stored in Service's caches or substituted for Service.Repo.
type refreshMetadata struct {
	Repository
	mu      sync.Mutex
	records map[string]gatewaycore.RepoRecord
	pages   map[refreshPageKey]*refreshPage
}

type refreshPageKey struct {
	did, collection, cursor string
	limit                   int
	reverse                 bool
}

type refreshPage struct {
	done chan struct{}
	page gatewaycore.RepoPage
	err  error
}

func newRefreshMetadata(repo Repository) *refreshMetadata {
	return &refreshMetadata{Repository: repo, records: map[string]gatewaycore.RepoRecord{}, pages: map[refreshPageKey]*refreshPage{}}
}

func (r *refreshMetadata) remember(record gatewaycore.RepoRecord) {
	_, collection, _, ok := parseURI(record.URI)
	if !ok {
		return
	}
	for _, candidate := range publicationCollections {
		if collection == candidate {
			r.mu.Lock()
			// Keep the record that discovery saw if sibling reads later overlap it.
			if _, exists := r.records[NormalizeATRepoParam(record.URI)]; !exists {
				r.records[NormalizeATRepoParam(record.URI)] = record
			}
			r.mu.Unlock()
			return
		}
	}
}

func (r *refreshMetadata) record(id string) *gatewaycore.RepoRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if record, ok := r.records[NormalizeATRepoParam(id)]; ok {
		return &record
	}
	return nil
}

func (r *refreshMetadata) GetRecord(ctx context.Context, did, collection, key, cid string) (*gatewaycore.RepoRecord, error) {
	record, err := r.Repository.GetRecord(ctx, did, collection, key, cid)
	if err == nil && record != nil {
		r.remember(*record)
	}
	return record, err
}

func (r *refreshMetadata) ListRecords(ctx context.Context, did, collection, cursor string, limit int, reverse bool) (gatewaycore.RepoPage, error) {
	if err := ctx.Err(); err != nil {
		return gatewaycore.RepoPage{}, err
	}
	key := refreshPageKey{did, collection, cursor, limit, reverse}
	r.mu.Lock()
	if hit, ok := r.pages[key]; ok {
		r.mu.Unlock()
		select {
		case <-ctx.Done():
			return gatewaycore.RepoPage{}, ctx.Err()
		case <-hit.done:
			return hit.page, hit.err
		}
	}
	entry := &refreshPage{done: make(chan struct{})}
	r.pages[key] = entry
	r.mu.Unlock()

	entry.page, entry.err = r.Repository.ListRecords(ctx, did, collection, cursor, limit, reverse)
	if entry.err == nil {
		for _, record := range entry.page.Records {
			r.remember(record)
		}
	}
	close(entry.done)
	return entry.page, entry.err
}
