package listcore

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type fixtureReader struct {
	records map[string]RecordRead
	values  map[string]json.RawMessage
}

func (f fixtureReader) Records(_ context.Context, did, collection string) (RecordRead, error) {
	return f.records[did+collection], nil
}
func (f fixtureReader) Record(_ context.Context, i Identity) (json.RawMessage, error) {
	return f.values[i.URI()], nil
}
func (f fixtureReader) Publication(context.Context, string) (*PublicationRead, error) {
	return nil, nil
}
func (f fixtureReader) CreatorDID(context.Context, string) (string, error) {
	return "did:plc:creator", nil
}

func fixtureList(name string) json.RawMessage {
	value, _ := json.Marshal(map[string]any{"name": name, "createdAt": "2026-10-06T00:00:00Z", "publications": []string{}})
	return value
}
func TestLoadRetainsOwnedRowsWhenSavedPublicRecordIsMissing(t *testing.T) {
	viewer := "did:plc:viewer"
	owned := Identity{viewer, "own"}.URI()
	missing := Identity{"did:plc:creator", "missing"}.URI()
	var ownValue map[string]json.RawMessage
	json.Unmarshal(fixtureList("Own"), &ownValue)
	saved, _ := json.Marshal(missing)
	reader := fixtureReader{records: map[string]RecordRead{
		viewer + Collection:     {Records: []gatewaycore.RepoRecord{{URI: owned, Value: ownValue}}, Complete: true},
		viewer + SaveCollection: {Records: []gatewaycore.RepoRecord{{Value: map[string]json.RawMessage{"list": saved}}}, Complete: true},
	}, values: map[string]json.RawMessage{}}
	response, err := Load(context.Background(), reader, viewer)
	if err != nil || len(response.Lists) != 1 || response.Lists[0].URI != owned || response.Complete {
		t.Fatalf("partial read hid valid row: %#v %v", response, err)
	}
}
func TestSearchUsesOwnedFirstAndNaturalOrdering(t *testing.T) {
	viewer := "did:plc:creator"
	records := []gatewaycore.RepoRecord{}
	for i, name := range []string{"List 10", "List 2", "List 1"} {
		var value map[string]json.RawMessage
		json.Unmarshal(fixtureList(name), &value)
		records = append(records, gatewaycore.RepoRecord{URI: Identity{viewer, fmt.Sprint(i)}.URI(), Value: value})
	}
	reader := fixtureReader{records: map[string]RecordRead{viewer + Collection: {Records: records, Complete: false}}}
	response, err := Search(context.Background(), reader, "creator.test", viewer, map[string]bool{records[1].URI: true})
	if err != nil || len(response.Lists) != 3 || response.Lists[0].Name != "List 1" || response.Lists[1].Name != "List 2" || !response.Lists[1].Saved || response.Complete || response.CreatorDID == nil {
		t.Fatalf("search contract: %#v %v", response, err)
	}
}
