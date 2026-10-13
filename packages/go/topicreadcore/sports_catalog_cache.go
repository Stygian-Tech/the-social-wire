package topicreadcore

import (
	"context"
	"database/sql"
	"errors"
	"sort"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type sportsCatalogIndexes struct {
	byID       map[string]sportscore.Entity
	resolver   *sportscore.EntityIndex
	selections *sportscore.SelectionFilter
}

type sportsPageCatalogCache struct {
	indexes      *sportsCatalogIndexes
	version      string
	generated    time.Time
	fullRevision string
	revision     string
	entities     []sportscore.Entity
}

func (s *SportsStore) cachedCatalog(ctx context.Context) ([]sportscore.Entity, bool, error) {
	s.catalogMu.Lock()
	cache := s.catalogCache
	s.catalogMu.Unlock()
	if cache == nil {
		if _, remote := s.Remote.(corpuscore.SportsSourceStore); !remote {
			return nil, false, nil
		}
	}
	// Workers publish a fresh immutable catalog version/generated-at and entity
	// projection in one transaction. Revalidate that lease on every page, including
	// continuations; no wall-clock freshness assumption enters cursor semantics.
	var version string
	var generated time.Time
	err := s.DB.QueryRowContext(ctx, `SELECT version,generated_at FROM wire_serving.sports_catalog LIMIT 1`).Scan(&version, &generated)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, false, err
	}
	if err == nil && cache != nil && version == cache.version && generated.Equal(cache.generated) {
		ObserveFeedPhase(ctx, "catalog-cache-hit", 0)
		return cache.entities, true, nil
	}
	ObserveFeedPhase(ctx, "catalog-cache-miss", 0)
	if err != nil {
		return nil, false, ErrUnavailable
	}
	entities, fullRevision, revision, err := s.loadSnapshotCatalog(ctx, version, generated)
	if err != nil {
		return nil, false, err
	}
	s.catalogMu.Lock()
	s.catalogCache = &sportsPageCatalogCache{version: version, generated: generated, fullRevision: fullRevision, revision: revision, entities: entities}
	s.catalogMu.Unlock()

	return entities, true, nil
}

func (s *SportsStore) servingCatalogRevision(entities []sportscore.Entity) (string, error) {
	s.catalogMu.Lock()
	cache := s.catalogCache
	s.catalogMu.Unlock()
	if cache != nil && len(entities) > 0 && len(entities) == len(cache.entities) && &entities[0] == &cache.entities[0] {
		return cache.revision, nil
	}
	return sportscore.ServingCatalogRevision(entities)
}

func (s *SportsStore) loadSnapshotCatalog(ctx context.Context, version string, generated time.Time) ([]sportscore.Entity, string, string, error) {
	var raw []byte
	started := time.Now()
	if err := s.DB.QueryRowContext(ctx, `SELECT entities::text FROM wire_serving.sports_catalog WHERE version=$1 AND generated_at=$2 LIMIT 1`, version, generated).Scan(&raw); err != nil {
		return nil, "", "", err
	}
	ObserveFeedPhase(ctx, "catalog-scan", time.Since(started))
	if err := ctx.Err(); err != nil {
		return nil, "", "", err
	}
	var full []sportscore.Entity
	started = time.Now()
	if corpuscore.DecodeContract(raw, &full) != nil || len(full) == 0 || len(full) > corpuscore.MaximumSportsEntities {
		return nil, "", "", ErrUnavailable
	}
	ObserveFeedPhase(ctx, "catalog-decode", time.Since(started))
	if err := ctx.Err(); err != nil {
		return nil, "", "", err
	}
	started = time.Now()
	fullRevision, err := sportscore.ServingCatalogRevision(full)
	if err != nil {
		return nil, "", "", err
	}
	active := []sportscore.Entity{}
	for _, e := range full {
		if e.Active {
			active = append(active, e)
		}
	}
	sort.SliceStable(active, func(i, j int) bool { return active[i].ID < active[j].ID })
	revision := fullRevision
	if len(active) != len(full) {
		revision, err = sportscore.ServingCatalogRevision(active)
		if err != nil {
			return nil, "", "", err
		}
	}
	ObserveFeedPhase(ctx, "catalog-revision", time.Since(started))
	if err := ctx.Err(); err != nil {
		return nil, "", "", err
	}
	return active, fullRevision, revision, nil
}

func (s *SportsStore) requireSourceCatalog(ctx context.Context, source corpuscore.SportsGeneration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.catalogMu.Lock()
	cache := s.catalogCache
	s.catalogMu.Unlock()
	if cache != nil && cache.version == source.CatalogVersion && cache.generated.Equal(source.CatalogGeneratedAt) && cache.fullRevision == source.CatalogRevision && cache.revision == source.ServingCatalogRevision {
		ObserveFeedPhase(ctx, "catalog-cache-hit", 0)
		return nil
	}
	ObserveFeedPhase(ctx, "catalog-cache-miss", 0)
	entities, fullRevision, revision, err := s.loadSnapshotCatalog(ctx, source.CatalogVersion, source.CatalogGeneratedAt)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return ErrUnavailable
	}
	if fullRevision != source.CatalogRevision || revision != source.ServingCatalogRevision {
		return ErrUnavailable
	}
	s.catalogMu.Lock()
	s.catalogCache = &sportsPageCatalogCache{version: source.CatalogVersion, generated: source.CatalogGeneratedAt, fullRevision: fullRevision, revision: revision, entities: entities}
	s.catalogMu.Unlock()
	return nil
}

func newSportsCatalogIndexes(entities []sportscore.Entity) *sportsCatalogIndexes {
	byID := make(map[string]sportscore.Entity, len(entities))
	for _, entity := range entities {
		if _, exists := byID[entity.ID]; !exists {
			byID[entity.ID] = entity
		}
	}
	return &sportsCatalogIndexes{byID: byID, resolver: sportscore.NewEntityIndex(entities), selections: sportscore.NewSelectionFilter(nil, entities)}
}

// Only the exact immutable slice validated by cachedCatalog owns shared indexes.
// A concurrent catalog replacement leaves in-flight pages using their own version;
// an uncached catalog is indexed afresh rather than trusted by a guessed key.
func (s *SportsStore) pageCatalogIndexes(ctx context.Context, entities []sportscore.Entity) (*sportsCatalogIndexes, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.catalogMu.Lock()
	cache := s.catalogCache
	if cache != nil && len(entities) > 0 && len(entities) == len(cache.entities) && &entities[0] == &cache.entities[0] {
		if cache.indexes == nil {
			cache.indexes = newSportsCatalogIndexes(entities)
		}
		indexes := cache.indexes
		s.catalogMu.Unlock()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return indexes, nil
	}
	s.catalogMu.Unlock()
	indexes := newSportsCatalogIndexes(entities)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return indexes, nil
}
