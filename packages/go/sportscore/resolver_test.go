package sportscore

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestResolverActualSwiftFixtures(t *testing.T) {
	data, err := os.ReadFile("resolver_fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Title    string          `json:"title"`
			Summary  *string         `json:"summary"`
			Expected json.RawMessage `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	index := NewEntityIndex(ReviewedEntities())
	for _, entry := range fixture.Cases {
		t.Run(entry.Title, func(t *testing.T) {
			summary := ""
			if entry.Summary != nil {
				summary = *entry.Summary
			}
			actual, err := json.Marshal(AnalyzeIndex(entry.Title, summary, index))
			if err != nil {
				t.Fatal(err)
			}
			var a, b any
			if err := json.Unmarshal(actual, &a); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(entry.Expected, &b); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(a, b) {
				t.Fatalf("actual %s\nexpected %s", actual, entry.Expected)
			}
		})
	}
}
