package readstatecore

import (
	"context"
	"encoding/json"
)

// Generation retains all verified chain evidence for transactional activation.
// No partial prefix is returned when a chain or resource bound fails.
type Generation struct {
	Projection      *Projection
	References      map[Reference]struct{}
	SourceBytes     int
	BytesByKind     map[string]int
	ChunksByKind    map[string]int
	AllowsRepacking bool
	Fragments       []V2Fragment
	Devices         []DeviceReceipt
	Legacy          []LegacyReceipt
}

// LoadRecords requires a fetch callback that verifies the original record's CID
// and exact viewer-owned URI before returning JSON, including unknown v1 fields.
func LoadRecords(ctx context.Context, manifest Manifest, viewer string, maximumChunks, maximumBytes int, fetchVerified func(context.Context, Reference) ([]byte, error)) (*Generation, error) {
	if err := ValidateManifest(manifest, viewer); err != nil {
		return nil, err
	}
	if maximumChunks < 0 || maximumBytes < 0 || fetchVerified == nil {
		return nil, ErrInvalidRecord
	}
	generation := &Generation{References: map[Reference]struct{}{}, BytesByKind: map[string]int{}, ChunksByKind: map[string]int{}, AllowsRepacking: true}
	roots := []struct {
		kind      string
		reference *Reference
	}{{"state", manifest.Head}}
	if manifest.Version == 2 {
		roots = []struct {
			kind      string
			reference *Reference
		}{{"state", manifest.StateHead}, {"devices", manifest.DevicesHead}, {"legacyReceipts", manifest.LegacyReceiptsHead}}
	}
	operations := []Operation{}
	for _, root := range roots {
		for reference := root.reference; reference != nil; {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if err := ValidateReference(*reference, viewer); err != nil {
				return nil, err
			}
			if _, visited := generation.References[*reference]; visited {
				return nil, ErrInvalidReference
			}
			generation.References[*reference] = struct{}{}
			if len(generation.References) > maximumChunks {
				return nil, ErrSizeLimit
			}
			data, err := fetchVerified(ctx, *reference)
			if err != nil {
				return nil, err
			}
			if len(data) > MaximumRecordBytes {
				return nil, ErrSizeLimit
			}
			accountedBytes := len(data)
			if manifest.Version == 1 {
				if err := validateV1RequiredShape(data); err != nil {
					return nil, err
				}
				var chunk Chunk
				if json.Unmarshal(data, &chunk) != nil {
					return nil, ErrInvalidRecord
				}
				if err := ValidateChunk(chunk, viewer); err != nil {
					return nil, err
				}
				known := knownV1Chunk(data)
				if known {
					encoded, err := EncodedBytes(chunk)
					if err != nil {
						return nil, err
					}
					accountedBytes = len(encoded)
				} else {
					accountedBytes = MaximumRecordBytes
					generation.AllowsRepacking = false
				}
				operations = append(operations, chunk.Operations...)
				reference = chunk.Previous
			} else {
				chunk, err := DecodeV2Chunk(data, viewer)
				if err != nil {
					return nil, err
				}
				if chunk.Kind != root.kind {
					return nil, ErrInvalidRecord
				}
				generation.Fragments = append(generation.Fragments, chunk.Fragments...)
				generation.Devices = append(generation.Devices, chunk.Devices...)
				generation.Legacy = append(generation.Legacy, chunk.Legacy...)
				reference = chunk.Previous
			}
			// Subtraction avoids overflow even when a caller supplies MaxInt limits.
			if accountedBytes > maximumBytes-generation.SourceBytes {
				return nil, ErrSizeLimit
			}
			generation.SourceBytes += accountedBytes
			generation.BytesByKind[root.kind] += accountedBytes
			generation.ChunksByKind[root.kind]++
		}
	}
	if manifest.Version == 2 {
		if err := validateV2Generation(generation, manifest.LastSequence, viewer); err != nil {
			return nil, err
		}
		for _, fragment := range generation.Fragments {
			operations = append(operations, fragment.Operation)
		}
	}
	projection, err := NewProjection(operations, manifest.LastSequence, manifest.Version)
	if err != nil {
		return nil, err
	}
	generation.Projection = projection
	return generation, nil
}

func knownV1Chunk(data []byte) bool {
	object, err := recordObject(data, []string{"$type", "version", "operations", "previous"}, []string{"$type", "version", "operations"})
	if err != nil || closedReference(object["previous"]) != nil {
		return false
	}
	var operations []json.RawMessage
	if json.Unmarshal(object["operations"], &operations) != nil {
		return false
	}
	for _, operation := range operations {
		if closedOperation(operation, false) != nil {
			return false
		}
	}
	return true
}

func validateV2Generation(generation *Generation, lastSequence int64, viewer string) error {
	devices := map[string]DeviceReceipt{}
	legacy := map[string]LegacyReceipt{}
	legacySequences := map[int64]bool{}
	legacySequence := int64(0)
	for _, receipt := range generation.Devices {
		if _, exists := devices[receipt.DeviceID]; exists {
			return ErrConflictingSequence
		}
		if receipt.CommittedCounter == 0 {
			initial, err := NewDeviceReceipt(viewer, receipt.DeviceID)
			if err != nil || initial != receipt {
				return ErrConflictingSequence
			}
		}
		devices[receipt.DeviceID] = receipt
	}
	for _, receipt := range generation.Legacy {
		if _, exists := legacy[receipt.ActionID]; exists || legacySequences[receipt.OriginalSequence] {
			return ErrConflictingSequence
		}
		if receipt.OriginalSequence > lastSequence {
			return ErrInvalidRecord
		}
		legacy[receipt.ActionID] = receipt
		legacySequences[receipt.OriginalSequence] = true
		legacySequence = max(legacySequence, receipt.OriginalSequence)
	}
	identities := map[string]V2Fragment{}
	type counterIdentity struct {
		device  string
		counter int64
	}
	counters := map[counterIdentity]string{}
	for _, fragment := range generation.Fragments {
		operation := fragment.Operation
		if previous, exists := identities[operation.ActionID]; exists {
			if previous.IntentHash != fragment.IntentHash || !sameOptional(previous.DeviceID, fragment.DeviceID) || !sameOptional(previous.DeviceCounter, fragment.DeviceCounter) || previous.Selection != fragment.Selection {
				return ErrConflictingSequence
			}
		}
		identities[operation.ActionID] = fragment
		if fragment.DeviceID != nil {
			receipt, exists := devices[*fragment.DeviceID]
			if !exists || *fragment.DeviceCounter > receipt.CommittedCounter || operation.Sequence <= legacySequence {
				return ErrIncompleteGeneration
			}
			if _, exists := legacy[operation.ActionID]; exists {
				return ErrIncompleteGeneration
			}
			key := counterIdentity{*fragment.DeviceID, *fragment.DeviceCounter}
			if action, exists := counters[key]; exists && action != operation.ActionID {
				return ErrConflictingSequence
			}
			counters[key] = operation.ActionID
		} else {
			receipt, exists := legacy[operation.ActionID]
			if !exists || receipt.OriginalSequence != operation.Sequence || receipt.OriginalIntentHash != fragment.IntentHash {
				return ErrIncompleteGeneration
			}
		}
	}
	return nil
}

func sameOptional[T comparable](left, right *T) bool {
	return left == nil && right == nil || left != nil && right != nil && *left == *right
}

func validateV1RequiredShape(data []byte) error {
	object, err := recordObject(data, nil, []string{"$type", "version", "operations"})
	if err != nil {
		return err
	}
	var operations []json.RawMessage
	if json.Unmarshal(object["operations"], &operations) != nil {
		return ErrInvalidRecord
	}
	for _, operation := range operations {
		value, err := recordObject(operation, nil, []string{"actionId", "sequence", "state", "actedAt", "selection"})
		if err != nil {
			return err
		}
		if calendar := value["calendar"]; len(calendar) > 0 && string(calendar) != "null" {
			if _, err := recordObject(calendar, nil, []string{"cutoff", "timeZone", "referenceDate"}); err != nil {
				return err
			}
		}
		if boundaries := value["boundaries"]; len(boundaries) > 0 && string(boundaries) != "null" {
			var values []json.RawMessage
			if json.Unmarshal(boundaries, &values) != nil {
				return ErrInvalidRecord
			}
			for _, boundary := range values {
				b, err := recordObject(boundary, nil, []string{"scope", "createdAt"})
				if err != nil {
					return err
				}
				if _, err := recordObject(b["scope"], nil, []string{"publicationId", "authorDid", "publicationSiteKeys"}); err != nil {
					return err
				}
			}
		}
	}
	if previous := object["previous"]; len(previous) > 0 && string(previous) != "null" {
		_, err := recordObject(previous, nil, []string{"uri", "cid"})
		return err
	}
	return nil
}
