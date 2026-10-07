package topicworkercore

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func (w *Worker) refreshSportsCatalog(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	previous, err := w.sportsCatalog(ctx)
	if err != nil {
		return err
	}
	definitions := sportscore.ReviewedEntities()
	byID := map[string]sportscore.Entity{}
	if previous != nil {
		for _, entity := range previous.Entities {
			if _, ok := byID[entity.ID]; !ok {
				byID[entity.ID] = entity
			}
		}
	}
	refresh := previous == nil
	if previous != nil {
		refresh = !(previous.Version == sportscore.ReviewedCatalogVersion || strings.HasPrefix(previous.Version, sportscore.ReviewedCatalogVersion+":")) || at.Sub(previous.GeneratedAt.Time) >= 24*time.Hour
		for _, definition := range definitions {
			existing, ok := byID[definition.ID]
			if !ok || existing.Name != definition.Name || existing.Kind != definition.Kind || !reflect.DeepEqual(existing.SportID, definition.SportID) || !reflect.DeepEqual(existing.SchoolID, definition.SchoolID) || !reflect.DeepEqual(existing.Gender, definition.Gender) || !reflect.DeepEqual(existing.Division, definition.Division) || !reflect.DeepEqual(existing.GroupPath, definition.GroupPath) {
				refresh = true
				break
			}
			for _, alias := range definition.Aliases {
				if !contains(existing.Aliases, alias) {
					refresh = true
					break
				}
			}
		}
	}
	if !refresh {
		return nil
	}
	entities := []sportscore.Entity{}
	reviewedIDs := map[string]bool{}
	for _, definition := range definitions {
		reviewedIDs[definition.ID] = true
		if existing, ok := byID[definition.ID]; ok && len(existing.ProviderIDs) > 0 {
			definition.CompetitionIDs = existing.CompetitionIDs
			definition.Aliases = unique(append(append([]string{}, definition.Aliases...), existing.Aliases...))
			definition.ProviderIDs = existing.ProviderIDs
			definition.Active = existing.Active
			definition.Memberships = existing.Memberships
			if definition.Abbreviation == nil {
				definition.Abbreviation = existing.Abbreviation
			}
		}
		entities = append(entities, definition)
	}
	if previous != nil {
		for _, entity := range previous.Entities {
			if len(entity.ProviderIDs) > 0 && !reviewedIDs[entity.ID] {
				entities = append(entities, entity)
			}
		}
	}
	return w.publishSportsCatalog(ctx, authority, entities, at)
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func (w *Worker) publishSportsCatalog(ctx context.Context, authority *operationscore.RoleLeaseAuthority, entities []sportscore.Entity, at time.Time) error {
	version, err := sportscore.CatalogRevision(entities)
	if err != nil {
		return err
	}
	snapshot := sportsSnapshot{version, swiftDate{at}, entities}
	payload, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	tx, err := w.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fence(ctx, tx, authority); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sports_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1,$2,$3,$4::jsonb,TRUE)`, identifier(), version, at, string(payload)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sports_entities(entity_id,payload,updated_at)SELECT value->>'id',value,$1 FROM jsonb_array_elements($2::jsonb->'entities')ON CONFLICT(entity_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at`, at, string(payload)); err != nil {
		return err
	}
	return tx.Commit()
}
