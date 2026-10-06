package readstatecore

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strings"
	"time"
)

var datePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$`)
var recordKeyPattern = regexp.MustCompile(`^[A-Za-z0-9.\-:_~]+$`)

func ParseDate(value string) (time.Time, error) {
	if !datePattern.MatchString(value) {
		return time.Time{}, ErrInvalidRecord
	}
	v, e := time.Parse(time.RFC3339Nano, value)
	if e != nil {
		return time.Time{}, ErrInvalidRecord
	}
	return v, nil
}
func ValidateReference(v Reference, viewer string) error {
	prefix := "at://" + viewer + "/" + ChunkCollection + "/"
	if !strings.HasPrefix(viewer, "did:") || !strings.HasPrefix(v.URI, prefix) || len(v.CID) == 0 || len(v.CID) > 256 {
		return ErrInvalidReference
	}
	key := strings.TrimPrefix(v.URI, prefix)
	if key == "" || key == "." || key == ".." || len(key) > 512 || !recordKeyPattern.MatchString(key) {
		return ErrInvalidReference
	}
	return nil
}
func EncodedBytes(v any) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}
func ValidateSize(v any) error {
	data, err := EncodedBytes(v)
	if err != nil {
		return err
	}
	if len(data) > MaximumRecordBytes {
		return ErrSizeLimit
	}
	return nil
}
func ValidateOperation(o Operation) error {
	if o.ActionID == "" || len(o.ActionID) > 128 || o.Sequence < 1 || o.Sequence > MaximumSequence || (o.State != Read && o.State != Unread) {
		return ErrInvalidRecord
	}
	if _, e := ParseDate(o.ActedAt); e != nil {
		return e
	}
	if o.Calendar != nil {
		if o.Selection != Exact {
			return ErrInvalidRecord
		}
		if _, e := time.LoadLocation(o.Calendar.TimeZone); e != nil {
			return ErrInvalidRecord
		}
		if _, e := time.Parse("2006-01-02", o.Calendar.ReferenceDate); e != nil {
			return ErrInvalidRecord
		}
		if _, e := ParseDate(o.Calendar.Cutoff); e != nil {
			return e
		}
	}
	switch o.Selection {
	case Exact:
		if o.Boundaries != nil || len(o.SubjectURIs) == 0 || len(o.SubjectURIs) > 256 {
			return ErrInvalidRecord
		}
		seen := map[string]bool{}
		for _, u := range o.SubjectURIs {
			if u == "" || len(u) > 2048 || seen[u] {
				return ErrInvalidRecord
			}
			seen[u] = true
		}
	case Boundaries:
		if o.SubjectURIs != nil || len(o.Boundaries) == 0 || len(o.Boundaries) > 128 {
			return ErrInvalidRecord
		}
		for _, b := range o.Boundaries {
			s := b.Scope
			if s.PublicationID == "" || len(s.PublicationID) > 2048 || !strings.HasPrefix(s.AuthorDID, "did:") || len(s.AuthorDID) > 2048 || len(s.PublicationSiteKeys) > 128 {
				return ErrInvalidRecord
			}
			for _, key := range s.PublicationSiteKeys {
				if key == "" || len(key) > 2048 {
					return ErrInvalidRecord
				}
			}
			if b.EntryID != nil && (*b.EntryID == "" || len(*b.EntryID) > 2048) {
				return ErrInvalidRecord
			}
			if _, e := ParseDate(b.CreatedAt); e != nil {
				return e
			}
		}
	default:
		return ErrInvalidRecord
	}
	return nil
}
func ValidateChunk(c Chunk, viewer string) error {
	if c.Type != ChunkCollection || c.Version != 1 || len(c.Operations) == 0 || len(c.Operations) > 128 {
		return ErrInvalidRecord
	}
	for _, o := range c.Operations {
		if e := ValidateOperation(o); e != nil {
			return e
		}
	}
	if c.Previous != nil {
		if e := ValidateReference(*c.Previous, viewer); e != nil {
			return e
		}
	}
	return ValidateSize(c)
}
func ValidateManifest(m Manifest, viewer string) error {
	if m.Type != ManifestCollection || (m.Version != 1 && m.Version != 2) || m.Generation == "" || len(m.Generation) > 128 || m.LastSequence < 0 || m.LastSequence > MaximumSequence {
		return ErrInvalidRecord
	}
	if m.Version == 1 {
		if (m.Head == nil && m.LastSequence != 0) || m.Revision != nil || m.StateHead != nil || m.DevicesHead != nil || m.LegacyReceiptsHead != nil || m.CompactionVersion != nil {
			return ErrInvalidRecord
		}
		if m.Head != nil {
			if e := ValidateReference(*m.Head, viewer); e != nil {
				return e
			}
		}
	} else {
		if m.Revision == nil || *m.Revision < 1 || *m.Revision > MaximumSequence || m.Head != nil || m.CompactionVersion == nil || *m.CompactionVersion != 1 || (m.LastSequence != 0 && m.StateHead == nil) {
			return ErrInvalidRecord
		}
		for _, r := range []*Reference{m.StateHead, m.DevicesHead, m.LegacyReceiptsHead} {
			if r != nil {
				if e := ValidateReference(*r, viewer); e != nil {
					return e
				}
			}
		}
	}
	return ValidateSize(m)
}
