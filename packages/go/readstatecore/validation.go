package readstatecore

// Checks timestamps, viewer-owned chunk references, selector exclusivity, record sizes,
// and version-specific manifest invariants. These checks cover the implemented models;
// they are not a strict closed-shape v2 loader and do not verify remote CID contents.

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var datePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$`)
var recordKeyPattern = regexp.MustCompile(`^[A-Za-z0-9.\-:_~]+$`)

// ParseDate accepts explicit-offset RFC3339 timestamps with up to nine fractional digits.
func ParseDate(value string) (time.Time, error) {
	if !datePattern.MatchString(value) {
		return time.Time{}, ErrInvalidRecord
	}
	parsedTime, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, ErrInvalidRecord
	}
	return parsedTime, nil
}

// ValidateReference checks that a chunk reference belongs to the viewer and has bounded
// URI key and CID fields.
func ValidateReference(reference Reference, viewer string) error {
	prefix := "at://" + viewer + "/" + ChunkCollection + "/"
	if !strings.HasPrefix(viewer, "did:") || !strings.HasPrefix(reference.URI, prefix) || len(reference.CID) == 0 || len(reference.CID) > 256 {
		return ErrInvalidReference
	}
	key := strings.TrimPrefix(reference.URI, prefix)
	if key == "" || key == "." || key == ".." || len(key) > 512 || !recordKeyPattern.MatchString(key) {
		return ErrInvalidReference
	}
	return nil
}

// EncodedBytes encodes JSON without HTML escaping or the encoder’s trailing newline.
func EncodedBytes(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), nil
}

// ValidateSize enforces the 64 KiB JSON record limit using the actual encoded bytes.
func ValidateSize(value any) error {
	data, err := EncodedBytes(value)
	if err != nil {
		return err
	}
	if len(data) > MaximumRecordBytes {
		return ErrSizeLimit
	}
	return nil
}

// ValidateOperation checks sequence/action metadata, selector bounds/exclusivity, dates,
// and calendar context.
func ValidateOperation(operation Operation) error {
	if operation.ActionID == "" || len(operation.ActionID) > 128 || operation.Sequence < 1 || operation.Sequence > MaximumSequence || (operation.State != Read && operation.State != Unread) {
		return ErrInvalidRecord
	}
	if _, err := ParseDate(operation.ActedAt); err != nil {
		return err
	}
	if operation.Calendar != nil {
		if operation.Selection != Exact {
			return ErrInvalidRecord
		}
		if _, err := time.LoadLocation(operation.Calendar.TimeZone); err != nil {
			return ErrInvalidRecord
		}
		if _, err := time.Parse("2006-01-02", operation.Calendar.ReferenceDate); err != nil {
			return ErrInvalidRecord
		}
		if _, err := ParseDate(operation.Calendar.Cutoff); err != nil {
			return err
		}
	}
	switch operation.Selection {
	case Exact:
		if operation.Boundaries != nil || len(operation.SubjectURIs) == 0 || len(operation.SubjectURIs) > 256 {
			return ErrInvalidRecord
		}
		seen := map[string]bool{}
		for _, subjectURI := range operation.SubjectURIs {
			if subjectURI == "" || len(subjectURI) > 2048 || seen[subjectURI] {
				return ErrInvalidRecord
			}
			seen[subjectURI] = true
		}
	case Boundaries:
		if operation.SubjectURIs != nil || len(operation.Boundaries) == 0 || len(operation.Boundaries) > 128 {
			return ErrInvalidRecord
		}
		for _, boundary := range operation.Boundaries {
			scope := boundary.Scope
			if scope.PublicationID == "" || len(scope.PublicationID) > 2048 || !strings.HasPrefix(scope.AuthorDID, "did:") || len(scope.AuthorDID) > 2048 || len(scope.PublicationSiteKeys) > 128 {
				return ErrInvalidRecord
			}
			for _, key := range scope.PublicationSiteKeys {
				if key == "" || len(key) > 2048 {
					return ErrInvalidRecord
				}
			}
			if boundary.EntryID != nil && (*boundary.EntryID == "" || len(*boundary.EntryID) > 2048) {
				return ErrInvalidRecord
			}
			if _, err := ParseDate(boundary.CreatedAt); err != nil {
				return err
			}
		}
	default:
		return ErrInvalidRecord
	}
	return nil
}

// ValidateChunk checks v1 type, operation count, previous reference ownership, and encoded
// size.
func ValidateChunk(chunk Chunk, viewer string) error {
	if chunk.Type != ChunkCollection || chunk.Version != 1 || len(chunk.Operations) == 0 || len(chunk.Operations) > 128 {
		return ErrInvalidRecord
	}
	for _, operation := range chunk.Operations {
		if err := ValidateOperation(operation); err != nil {
			return err
		}
	}
	if chunk.Previous != nil {
		if err := ValidateReference(*chunk.Previous, viewer); err != nil {
			return err
		}
	}
	return ValidateSize(chunk)
}

// ValidateManifest checks implemented version-specific head/sequence/revision invariants
// and encoded size.
func ValidateManifest(manifest Manifest, viewer string) error {
	if manifest.Type != ManifestCollection || (manifest.Version != 1 && manifest.Version != 2) || manifest.Generation == "" || len(manifest.Generation) > 128 || manifest.LastSequence < 0 || manifest.LastSequence > MaximumSequence {
		return ErrInvalidRecord
	}
	if manifest.Version == 1 {
		if (manifest.Head == nil && manifest.LastSequence != 0) || manifest.Revision != nil || manifest.StateHead != nil || manifest.DevicesHead != nil || manifest.LegacyReceiptsHead != nil || manifest.CompactionVersion != nil {
			return ErrInvalidRecord
		}
		if manifest.Head != nil {
			if err := ValidateReference(*manifest.Head, viewer); err != nil {
				return err
			}
		}
	} else {
		if manifest.Revision == nil || *manifest.Revision < 1 || *manifest.Revision > MaximumSequence || manifest.Head != nil || manifest.CompactionVersion == nil || *manifest.CompactionVersion != 1 || (manifest.LastSequence != 0 && manifest.StateHead == nil) {
			return ErrInvalidRecord
		}
		for _, reference := range []*Reference{manifest.StateHead, manifest.DevicesHead, manifest.LegacyReceiptsHead} {
			if reference != nil {
				if err := ValidateReference(*reference, viewer); err != nil {
					return err
				}
			}
		}
	}
	return ValidateSize(manifest)
}
