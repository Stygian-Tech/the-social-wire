package spec

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestGeneratedAPIContractsMatchCanonicalSources(t *testing.T) {
	data, err := os.ReadFile("../../spec/endpoint-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var expected struct {
		Entries []Endpoint `json:"entries"`
	}
	if err := json.Unmarshal(data, &expected); err != nil {
		t.Fatal(err)
	}
	entries, err := Endpoints()
	if err != nil {
		t.Fatal(err)
	}
	actualJSON, _ := json.Marshal(entries)
	expectedJSON, _ := json.Marshal(expected.Entries)
	if string(actualJSON) != string(expectedJSON) {
		t.Fatal("endpoint manifest drift")
	}
	source, err := os.ReadFile("../../spec/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(source)
	if string(source) != OpenAPI || hex.EncodeToString(digest[:]) != OpenAPISHA256 {
		t.Fatal("OpenAPI drift")
	}
	if len(entries) == 0 {
		t.Fatal("empty manifest")
	}
	entry, ok := Find(entries[0].Surface, entries[0].Method, entries[0].Path)
	if !ok || entry != entries[0] {
		t.Fatal("lookup failed")
	}
}

func TestCanonicalOpenAPIBuildsWith31Parser(t *testing.T) {
	document, err := OpenAPIDocument()
	if err != nil {
		t.Fatal(err)
	}
	model, err := document.BuildV3Model()
	if err != nil {
		t.Fatal(err)
	}
	if model == nil || model.Model.Version != "3.1.0" || model.Model.Paths == nil {
		t.Fatal("canonical OpenAPI 3.1 model missing")
	}
}
