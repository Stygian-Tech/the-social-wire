package sportscore

import "testing"

func TestReviewedRevisionMatchesActualSwift(t *testing.T) {
	revision, err := CatalogRevision(ReviewedEntities())
	if err != nil {
		t.Fatal(err)
	}
	if revision != "sports-reviewed-v12:9b0bad3c40e273024e189f74c589295fd05db953f2e496533767ac1e5cf6aa6f" {
		t.Fatalf("revision mismatch %s", revision)
	}
}
