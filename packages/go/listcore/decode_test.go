package listcore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestListValidationPreservesGraphemesAndArrayAbsence(t *testing.T) {
	identity := Identity{DID: "did:plc:creator", RKey: "list"}
	value := map[string]any{"name": strings.Repeat("e\u0301", 64), "createdAt": "2026-10-06T00:00:00Z", "publications": []string{"at://did:plc:creator/site.standard.publication/a", "at://did:plc:creator/site.standard.publication/a"}, "description": 123}
	data, _ := json.Marshal(value)
	list, err := Decode(data, identity, identity.DID, true)
	if err != nil || list == nil || len(list.Publications) != 1 || list.Users == nil || len(list.Users) != 0 || list.Description != nil || !list.Owned || !list.Saved {
		t.Fatalf("valid record lost: %#v %v", list, err)
	}
	value["users"] = nil
	data, _ = json.Marshal(value)
	if list, _ := Decode(data, identity, identity.DID, false); list != nil {
		t.Fatal("explicit null users accepted")
	}
	delete(value, "users")
	value["name"] = strings.Repeat("e\u0301", 65)
	data, _ = json.Marshal(value)
	if list, _ := Decode(data, identity, identity.DID, false); list != nil {
		t.Fatal("overlong grapheme name accepted")
	}
}
