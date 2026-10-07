package readstatecore

import (
	"bytes"
	"encoding/json"
	"slices"
)

// recordObject rejects unknown v2 semantics before typed decoding can discard them.
func recordObject(data []byte, allowed, required []string) (map[string]json.RawMessage, error) {
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil || object == nil {
		return nil, ErrInvalidRecord
	}
	for key := range object {
		if allowed != nil && !slices.Contains(allowed, key) {
			return nil, ErrInvalidRecord
		}
	}
	for _, key := range required {
		if value, ok := object[key]; !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, ErrInvalidRecord
		}
	}
	return object, nil
}

func closedReference(data json.RawMessage) error {
	if len(data) == 0 || bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		return nil
	}
	_, err := recordObject(data, []string{"uri", "cid"}, []string{"uri", "cid"})
	return err
}

func closedOperation(data []byte, fragment bool) error {
	allowed := []string{"actionId", "sequence", "state", "actedAt", "selection", "subjectUris", "boundaries", "calendar"}
	required := []string{"actionId", "sequence", "state", "actedAt", "selection"}
	if fragment {
		allowed = append(allowed, "fragment", "intentHash", "deviceId", "deviceCounter")
		required = append(required, "fragment", "intentHash")
	}
	object, err := recordObject(data, allowed, required)
	if err != nil {
		return err
	}
	if calendar := object["calendar"]; len(calendar) > 0 && !bytes.Equal(bytes.TrimSpace(calendar), []byte("null")) {
		if _, err := recordObject(calendar, []string{"cutoff", "timeZone", "referenceDate"}, []string{"cutoff", "timeZone", "referenceDate"}); err != nil {
			return err
		}
	}
	if boundaries := object["boundaries"]; len(boundaries) > 0 && !bytes.Equal(bytes.TrimSpace(boundaries), []byte("null")) {
		var values []json.RawMessage
		if json.Unmarshal(boundaries, &values) != nil {
			return ErrInvalidRecord
		}
		for _, value := range values {
			boundary, err := recordObject(value, []string{"scope", "createdAt", "entryId"}, []string{"scope", "createdAt"})
			if err != nil {
				return err
			}
			if _, err := recordObject(boundary["scope"], []string{"publicationId", "authorDid", "publicationSiteKeys"}, []string{"publicationId", "authorDid", "publicationSiteKeys"}); err != nil {
				return err
			}
		}
	}
	return nil
}

// DecodeManifest preserves permissive v1 reading and enforces the closed v2 shape.
func DecodeManifest(data []byte, viewer string) (Manifest, error) {
	var manifest Manifest
	if len(data) > MaximumRecordBytes {
		return manifest, ErrSizeLimit
	}
	if _, err := recordObject(data, nil, []string{"$type", "version", "generation", "lastSequence"}); err != nil {
		return manifest, err
	}
	if json.Unmarshal(data, &manifest) != nil {
		return manifest, ErrInvalidRecord
	}
	if manifest.Version == 2 {
		object, err := recordObject(data, []string{"$type", "version", "generation", "revision", "lastSequence", "stateHead", "devicesHead", "legacyReceiptsHead", "compactionVersion"}, []string{"$type", "version", "generation", "revision", "lastSequence", "compactionVersion"})
		if err != nil {
			return manifest, err
		}
		for _, key := range []string{"stateHead", "devicesHead", "legacyReceiptsHead"} {
			if err := closedReference(object[key]); err != nil {
				return manifest, err
			}
		}
	}
	return manifest, ValidateManifest(manifest, viewer)
}
