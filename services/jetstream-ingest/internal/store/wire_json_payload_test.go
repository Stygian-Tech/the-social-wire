package store

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestNormalizeWireJSONPayloadForPostgres(t *testing.T) {
	tests := []struct {
		name    string
		payload []byte
		want    []byte
	}{
		{
			name:    "leaves ordinary payload byte-identical",
			payload: []byte(`{"record":{"text":"ordinary"},"cursor":24924930989}`),
			want:    []byte(`{"record":{"text":"ordinary"},"cursor":24924930989}`),
		},
		{
			name:    "replaces escaped NUL in nested values and keys",
			payload: []byte(`{"record":{"before\u0000after":["one\u0000two"]}}`),
			want:    []byte("{\"record\":{\"before�after\":[\"one�two\"]}}"),
		},
		{
			name:    "preserves a literal backslash-u sequence",
			payload: []byte(`{"record":{"text":"literal \\u0000 text"}}`),
			want:    []byte(`{"record":{"text":"literal \\u0000 text"}}`),
		},
		{
			name:    "normalizes an unsupported unpaired surrogate",
			payload: []byte(`{"record":{"text":"before\ud800after"}}`),
			want:    []byte("{\"record\":{\"text\":\"before�after\"}}"),
		},
		{
			name:    "replaces a raw NUL inside a string",
			payload: []byte("{\"record\":{\"text\":\"before\x00after\"}}"),
			want:    []byte("{\"record\":{\"text\":\"before�after\"}}"),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := normalizeWireJSONPayloadForPostgres(test.payload)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, test.want) {
				t.Fatalf("normalized payload = %s, want %s", got, test.want)
			}
			if !json.Valid(got) {
				t.Fatalf("normalized payload is invalid JSON: %s", got)
			}
		})
	}
}

func TestNormalizeWireJSONPayloadPreservesValidUnicodeSemantics(t *testing.T) {
	payload := []byte(`{"record":{"emoji":"\ud83d\ude00","accent":"\u00e9"},"cursor":9223372036854775807}`)
	normalized, err := normalizeWireJSONPayloadForPostgres(payload)
	if err != nil {
		t.Fatal(err)
	}
	var before any
	var after any
	if err := json.Unmarshal(payload, &before); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(normalized, &after); err != nil {
		t.Fatal(err)
	}
	if !deepEqualJSON(before, after) {
		t.Fatalf("valid Unicode semantics changed: before=%#v after=%#v", before, after)
	}
	if !bytes.Contains(normalized, []byte("9223372036854775807")) {
		t.Fatalf("large integer lexeme changed: %s", normalized)
	}
	again, err := normalizeWireJSONPayloadForPostgres(normalized)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again, normalized) {
		t.Fatalf("normalization is not idempotent: first=%s second=%s", normalized, again)
	}
}

func TestNormalizeWireJSONPayloadRejectsInvalidStructure(t *testing.T) {
	for _, payload := range [][]byte{
		[]byte(`{"record":`),
		[]byte("{\x00\"record\":{}}"),
	} {
		if _, err := normalizeWireJSONPayloadForPostgres(payload); err == nil {
			t.Fatalf("expected invalid payload rejection: %q", payload)
		}
	}
}

func TestNormalizeWireJSONPayloadRejectsKeyCollision(t *testing.T) {
	payload := []byte(`{"record":{"same\u0000key":1,"same\ufffdkey":2}}`)
	if _, err := normalizeWireJSONPayloadForPostgres(payload); err == nil {
		t.Fatal("expected normalized object-key collision rejection")
	}
}

func TestWireJSONPayloadForPostgresFallsBackWithoutSkipping(t *testing.T) {
	tests := []struct {
		name    string
		payload []byte
	}{
		{name: "invalid structure", payload: []byte(`{"record":`)},
		{
			name:    "normalized key collision",
			payload: []byte(`{"record":{"same\u0000key":1,"same\ufffdkey":2}}`),
		},
		{name: "raw NUL outside string", payload: []byte("{\x00\"record\":{}}")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stored := wireJSONPayloadForPostgres(test.payload)
			var fallback wirePayloadNormalizationFailure
			if err := json.Unmarshal(stored, &fallback); err != nil {
				t.Fatalf("fallback is not valid JSON: %v; payload=%s", err, stored)
			}
			if fallback.Error.Code != wirePayloadNormalizationFailureCode ||
				fallback.Error.Version != 1 || fallback.Error.OriginalBytes != len(test.payload) {
				t.Fatalf("fallback metadata = %#v", fallback.Error)
			}
		})
	}
}

func deepEqualJSON(left, right any) bool {
	leftJSON, leftErr := json.Marshal(left)
	rightJSON, rightErr := json.Marshal(right)
	return leftErr == nil && rightErr == nil && bytes.Equal(leftJSON, rightJSON)
}
