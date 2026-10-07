package readstatecore

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestGenerationLoadsAllV2ChainsAndRejectsMissingReceipts(t *testing.T) {
	viewer := "did:plc:fixture"
	device := "01234567-89ab-cdef-0123-456789abcdef"
	counter := int64(1)
	revision := int64(2)
	compaction := 1
	fragment := V2Fragment{Operation: Operation{ActionID: "a", Sequence: 1, State: Read, ActedAt: "2026-10-06T00:00:00Z", Selection: Exact, SubjectURIs: []string{"at://did:plc:author/site.standard.document/a"}}, Fragment: true, IntentHash: strings.Repeat("a", 64), DeviceID: &device, DeviceCounter: &counter}
	data, _ := json.Marshal(map[string]any{"$type": ChunkCollection, "version": 2, "kind": "state", "fragments": []V2Fragment{fragment}})
	deviceData, _ := json.Marshal(map[string]any{"$type": ChunkCollection, "version": 2, "kind": "devices", "receipts": []DeviceReceipt{{device, 1, strings.Repeat("b", 64)}}})
	state := Reference{"at://" + viewer + "/" + ChunkCollection + "/state", "state"}
	devices := Reference{"at://" + viewer + "/" + ChunkCollection + "/devices", "devices"}
	manifest := Manifest{Type: ManifestCollection, Version: 2, Generation: "g", LastSequence: 1, Revision: &revision, StateHead: &state, DevicesHead: &devices, CompactionVersion: &compaction}
	fetch := func(_ context.Context, ref Reference) ([]byte, error) {
		if ref == devices {
			return deviceData, nil
		}
		return data, nil
	}
	loaded, err := LoadRecords(context.Background(), manifest, viewer, 4096, 16*1024*1024, fetch)
	if err != nil || len(loaded.References) != 2 || len(loaded.Devices) != 1 || len(loaded.Fragments) != 1 {
		t.Fatal(loaded, err)
	}
	manifest.DevicesHead = nil
	if _, err := LoadRecords(context.Background(), manifest, viewer, 4096, 16*1024*1024, fetch); err == nil {
		t.Fatal("accepted missing receipt")
	}
	manifest.DevicesHead = &devices
	if _, err := LoadRecords(context.Background(), manifest, viewer, 1, 16*1024*1024, fetch); err == nil {
		t.Fatal("accepted chunk limit")
	}
	if _, err := LoadRecords(context.Background(), manifest, viewer, 4096, 1, fetch); err == nil {
		t.Fatal("accepted byte limit")
	}
	deviceData = []byte(strings.Replace(string(deviceData), `"committedCounter":1`, `"committedCounter":0`, 1))
	if _, err := LoadRecords(context.Background(), manifest, viewer, 4096, 16*1024*1024, fetch); err == nil {
		t.Fatal("accepted unacknowledged counter")
	}
}

func TestV1ExtensionsAreConservativelyAccountedAndCyclesFail(t *testing.T) {
	viewer := "did:plc:fixture"
	ref := Reference{"at://" + viewer + "/" + ChunkCollection + "/one", "cid"}
	data := []byte(`{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"a","sequence":1,"state":"read","actedAt":"2026-10-06T00:00:00Z","selection":"exact","subjectUris":["one"]}],"future":true}`)
	manifest := Manifest{Type: ManifestCollection, Version: 1, Generation: "g", LastSequence: 1, Head: &ref}
	fetch := func(context.Context, Reference) ([]byte, error) { return data, nil }
	loaded, err := LoadRecords(context.Background(), manifest, viewer, 2, MaximumRecordBytes, fetch)
	if err != nil || loaded.AllowsRepacking || loaded.SourceBytes != MaximumRecordBytes {
		t.Fatal(loaded, err)
	}
	if _, err := LoadRecords(context.Background(), manifest, viewer, 2, MaximumRecordBytes-1, fetch); err == nil {
		t.Fatal("accepted unknown-field accounting overflow")
	}
	var chunk map[string]any
	json.Unmarshal(data, &chunk)
	chunk["previous"] = ref
	data, _ = json.Marshal(chunk)
	if _, err := LoadRecords(context.Background(), manifest, viewer, 2, 2*MaximumRecordBytes, fetch); err == nil {
		t.Fatal("accepted cycle")
	}
}

func TestV2NestedUnknownShapesFailClosed(t *testing.T) {
	for _, data := range []string{
		`{"$type":"app.thesocialwire.readStateChunk","version":2,"kind":"devices","receipts":[{"deviceId":"01234567-89ab-cdef-0123-456789abcdef","committedCounter":1,"prefixHash":"` + strings.Repeat("a", 64) + `","future":true}]}`,
		`{"$type":"app.thesocialwire.readStateChunk","version":2,"kind":"state","fragments":[{"actionId":"a","sequence":1,"state":"read","actedAt":"2026-10-06T00:00:00Z","selection":"boundaries","fragment":true,"intentHash":"` + strings.Repeat("a", 64) + `","boundaries":[{"scope":{"publicationId":"p","authorDid":"did:plc:author"},"createdAt":"2026-10-06T00:00:00Z"}]}]}`,
	} {
		if _, err := DecodeV2Chunk([]byte(data), "did:plc:fixture"); err == nil {
			t.Fatal("accepted unknown/incomplete shape")
		}
	}
}
