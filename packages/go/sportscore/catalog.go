package sportscore

import (
	_ "embed"
	"encoding/json"
)

const ReviewedCatalogVersion = "sports-reviewed-v12"

//go:embed reviewed_catalog.json
var reviewedCatalogJSON []byte

func ReviewedEntities() []Entity {
	var values []Entity
	if err := json.Unmarshal(reviewedCatalogJSON, &values); err != nil {
		panic(err)
	}
	return values
}
func ReviewedID(key string) string { return EntityID("reviewed:" + key) }
