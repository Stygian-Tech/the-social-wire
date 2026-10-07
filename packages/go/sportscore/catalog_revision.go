package sportscore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"time"
)

// CatalogRevision normalizes membership/alias order and uses the reference Swift
// sorted-key JSON encoding, including its escaped slash and 2001-epoch dates.
func CatalogRevision(entities []Entity) (string, error) {
	copyEntities := append([]Entity{}, entities...)
	sort.Slice(copyEntities, func(i, j int) bool { return copyEntities[i].ID < copyEntities[j].ID })
	normalized := []map[string]any{}
	for _, entity := range copyEntities {
		memberships := append([]Membership{}, entity.Memberships...)
		sort.SliceStable(memberships, func(i, j int) bool {
			a, b := memberships[i], memberships[j]
			if a.EntityID != b.EntityID {
				return a.EntityID < b.EntityID
			}
			if !a.ValidFrom.Equal(b.ValidFrom) {
				return a.ValidFrom.Before(b.ValidFrom)
			}
			end := func(value *time.Time) time.Time {
				if value == nil {
					return time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
				}
				return *value
			}
			if !end(a.ValidUntil).Equal(end(b.ValidUntil)) {
				return end(a.ValidUntil).Before(end(b.ValidUntil))
			}
			season := func(value *string) string {
				if value == nil {
					return ""
				}
				return *value
			}
			return season(a.Season) < season(b.Season)
		})
		relations := []map[string]any{}
		date := func(value time.Time) float64 {
			return float64(value.Unix()-978307200) + float64(value.Nanosecond())/1e9
		}
		for _, m := range memberships {
			relation := map[string]any{"entityID": m.EntityID, "validFrom": date(m.ValidFrom)}
			if m.ValidUntil != nil {
				relation["validUntil"] = date(*m.ValidUntil)
			}
			if m.Season != nil {
				relation["season"] = *m.Season
			}
			relations = append(relations, relation)
		}
		providers := entity.ProviderIDs
		if providers == nil {
			providers = map[string]string{}
		}
		row := map[string]any{"id": entity.ID, "name": entity.Name, "kind": entity.Kind, "competitionIDs": uniqueSorted(entity.CompetitionIDs), "aliases": uniqueSorted(entity.Aliases), "providerIDs": providers, "active": entity.Active, "memberships": relations}
		for key, value := range map[string]*string{"schoolID": entity.SchoolID, "gender": entity.Gender, "division": entity.Division, "sportID": entity.SportID, "abbreviation": entity.Abbreviation} {
			if value != nil {
				row[key] = *value
			}
		}
		if entity.GroupPath != nil {
			row["groupPath"] = entity.GroupPath
		}
		normalized = append(normalized, row)
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(normalized); err != nil {
		return "", err
	}
	data := strings.ReplaceAll(strings.TrimSuffix(buffer.String(), "\n"), "/", "\\/")
	sum := sha256.Sum256([]byte(data))
	return ReviewedCatalogVersion + ":" + hex.EncodeToString(sum[:]), nil
}
