package pdsreadstatecore

import (
	"context"
	"strings"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

// Confirm reads only public viewer-owned records, verifies original CIDs, and
// rereads the manifest before atomically changing read-state authority.
func (s *Store) Confirm(ctx context.Context, viewer, candidateCID string, expectedLegacyRevision *int64) (Status, error) {
	if s.FetchRecord == nil {
		return Status{}, ErrProjectionUnavailable
	}
	if candidateCID == "" || len(candidateCID) > 256 {
		return Status{}, r.ErrInvalidReference
	}
	data, cid, err := s.fetch(ctx, viewer, r.ManifestCollection, "self", nil)
	if err != nil {
		return Status{}, err
	}
	if cid != candidateCID {
		return Status{}, ErrStaleGeneration
	}
	manifest, err := r.DecodeManifest(data, viewer)
	if err != nil {
		return Status{}, err
	}
	generation, err := r.LoadRecords(ctx, manifest, viewer, 4096, 16*1024*1024, func(ctx context.Context, reference r.Reference) ([]byte, error) {
		key := reference.URI[strings.LastIndex(reference.URI, "/")+1:]
		data, _, err := s.fetch(ctx, viewer, r.ChunkCollection, key, &reference.CID)
		return data, err
	})
	if err != nil {
		return Status{}, err
	}
	_, currentCID, err := s.fetch(ctx, viewer, r.ManifestCollection, "self", nil)
	if err != nil {
		return Status{}, err
	}
	if currentCID != cid {
		return Status{}, ErrStaleGeneration
	}
	if err := s.activateWithRevision(ctx, viewer, manifest, cid, data, generation, expectedLegacyRevision); err != nil {
		return Status{}, err
	}
	return s.Status(ctx, viewer)
}
