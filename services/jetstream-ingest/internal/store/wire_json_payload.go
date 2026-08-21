package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

var escapedUnicodeMarker = []byte(`\u`)

const wirePayloadNormalizationFailureCode = "payload_normalization_failed"

type wirePayloadNormalizationFailure struct {
	Error struct {
		Code          string `json:"code"`
		Version       int    `json:"version"`
		OriginalBytes int    `json:"originalBytes"`
	} `json:"$wireIngestionError"`
}

// normalizeWireJSONPayloadForPostgres preserves the event envelope while replacing string code
// points that PostgreSQL JSONB cannot represent. PostgreSQL stores JSONB strings as text, so
// U+0000 is rejected even though it is valid JSON. UseNumber prevents cursor and timestamp
// integers from being coerced through float64 while recursively normalizing values and keys.
func normalizeWireJSONPayloadForPostgres(payload []byte) ([]byte, error) {
	withoutRawNUL, replacedRawNUL, err := replaceRawNULInJSONStrings(payload)
	if err != nil {
		return nil, err
	}
	if !replacedRawNUL && !bytes.Contains(withoutRawNUL, escapedUnicodeMarker) {
		if !json.Valid(withoutRawNUL) {
			return nil, errors.New("payload is not valid JSON")
		}
		return payload, nil
	}

	decoder := json.NewDecoder(bytes.NewReader(withoutRawNUL))
	decoder.UseNumber()
	var document any
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode JSON payload: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("payload contains multiple JSON values")
		}
		return nil, fmt.Errorf("decode trailing JSON payload: %w", err)
	}
	root, ok := document.(map[string]any)
	if !ok {
		return nil, errors.New("payload must be a JSON object")
	}
	normalized, _, err := normalizeJSONValue(root)
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(normalized)
	if err != nil {
		return nil, fmt.Errorf("encode normalized JSON payload: %w", err)
	}
	return encoded, nil
}

func wireJSONPayloadForPostgres(payload []byte) []byte {
	normalized, err := normalizeWireJSONPayloadForPostgres(payload)
	if err != nil {
		return wireJSONPayloadFallback(len(payload))
	}
	return normalized
}

func wireJSONPayloadFallback(originalBytes int) []byte {
	var fallback wirePayloadNormalizationFailure
	fallback.Error.Code = wirePayloadNormalizationFailureCode
	fallback.Error.Version = 1
	fallback.Error.OriginalBytes = originalBytes
	payload, err := json.Marshal(fallback)
	if err != nil {
		panic(fmt.Sprintf("marshal static Wire payload fallback: %v", err))
	}
	return payload
}

func normalizeJSONValue(value any) (any, bool, error) {
	switch typed := value.(type) {
	case string:
		normalized := strings.ReplaceAll(typed, "\x00", "\uFFFD")
		return normalized, normalized != typed, nil
	case []any:
		changed := false
		for index := range typed {
			normalized, itemChanged, err := normalizeJSONValue(typed[index])
			if err != nil {
				return nil, false, err
			}
			typed[index] = normalized
			changed = changed || itemChanged
		}
		return typed, changed, nil
	case map[string]any:
		normalized := make(map[string]any, len(typed))
		changed := false
		for key, item := range typed {
			normalizedKey := strings.ReplaceAll(key, "\x00", "\uFFFD")
			if _, exists := normalized[normalizedKey]; exists {
				return nil, false, fmt.Errorf("normalizing JSON object key %q creates a duplicate", key)
			}
			normalizedItem, itemChanged, err := normalizeJSONValue(item)
			if err != nil {
				return nil, false, err
			}
			normalized[normalizedKey] = normalizedItem
			changed = changed || normalizedKey != key || itemChanged
		}
		return normalized, changed, nil
	case nil, bool, json.Number:
		return value, false, nil
	default:
		return nil, false, fmt.Errorf("unsupported decoded JSON value %T", value)
	}
}

func replaceRawNULInJSONStrings(payload []byte) ([]byte, bool, error) {
	var output []byte
	lastCopied := 0
	inString := false
	escaped := false
	for index, value := range payload {
		if value == 0 {
			if !inString {
				return nil, false, errors.New("raw NUL outside a JSON string")
			}
			output = append(output, payload[lastCopied:index]...)
			output = append(output, `\ufffd`...)
			lastCopied = index + 1
			continue
		}
		if !inString {
			if value == '"' {
				inString = true
			}
			continue
		}
		if escaped {
			escaped = false
			continue
		}
		switch value {
		case '\\':
			escaped = true
		case '"':
			inString = false
		}
	}
	if output == nil {
		return payload, false, nil
	}
	return append(output, payload[lastCopied:]...), true, nil
}
