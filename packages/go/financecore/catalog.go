package financecore

import (
	_ "embed"
	"encoding/json"
)

const ReviewedCatalogVersion = "reviewed-v3"
const ReviewedMetadataVersion = "reviewed-metadata-v4"

// Reviewed identity data, exported from the actual reference catalog for parity.
//
//go:embed reviewed_catalog.json
var reviewedCatalogJSON []byte

//go:embed reviewed_metadata.json
var reviewedMetadataJSON []byte

func ReviewedInstruments() []Instrument {
	var values []Instrument
	if err := json.Unmarshal(reviewedCatalogJSON, &values); err != nil {
		panic(err)
	}
	return values
}
func ReviewedEntries() []ReviewedMetadata {
	var values []ReviewedMetadata
	if err := json.Unmarshal(reviewedMetadataJSON, &values); err != nil {
		panic(err)
	}
	return values
}
