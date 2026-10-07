// Package pdsreadstatecore activates complete, CID-verified viewer generations.
package pdsreadstatecore

import (
	"context"
	"database/sql"
	"errors"
	"reflect"
	"strings"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

var ErrStaleGeneration = errors.New("stale PDS read-state generation")
var ErrProjectionUnavailable = errors.New("PDS read-state projection unavailable")

type FetchRecord func(context.Context, string, string, string, *string) (string, string, []byte, error)
type Store struct {
	DB          *sql.DB
	FetchRecord FetchRecord
}

func (s *Store) PDSAuthority(ctx context.Context, viewer string) (bool, error) {
	var result bool
	err := s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM appview_pds_read_state_authority WHERE viewer_did=$1 AND manifest_cid IS NOT NULL)`, viewer).Scan(&result)
	return result, err
}

func (s *Store) IsRead(ctx context.Context, viewer, subject string) (bool, error) {
	var pds, ready bool
	err := s.DB.QueryRowContext(ctx, `SELECT manifest_cid IS NOT NULL, projection_ready FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&pds, &ready)
	if err != nil && err != sql.ErrNoRows {
		return false, err
	}
	if !pds || !ready {
		return false, ErrProjectionUnavailable
	}
	var result bool
	err = s.DB.QueryRowContext(ctx, `SELECT appview_pds_entry_is_read($1,uri,author_did,publication_site,created_at) FROM content_items WHERE uri=$2`, viewer, subject).Scan(&result)
	if err == sql.ErrNoRows {
		return false, nil
	}
	return result, err
}

func (s *Store) fetch(ctx context.Context, viewer, collection, key string, expected *string) ([]byte, string, error) {
	uri, cid, data, err := s.FetchRecord(ctx, viewer, collection, key, expected)
	if err != nil {
		return nil, "", err
	}
	if uri != "at://"+viewer+"/"+collection+"/"+key || (expected != nil && cid != *expected) {
		return nil, "", r.ErrInvalidReference
	}
	if err := r.VerifyRecordCID(data, cid); err != nil {
		return nil, "", err
	}
	return data, cid, nil
}

func (s *Store) Reconcile(ctx context.Context, viewer string, rebuildEvicted bool) (bool, error) {
	var active, ready bool
	err := s.DB.QueryRowContext(ctx, `SELECT manifest_cid IS NOT NULL, projection_ready FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&active, &ready)
	if err == sql.ErrNoRows || (err == nil && (!active || (!ready && !rebuildEvicted))) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if s.FetchRecord == nil {
		return false, ErrProjectionUnavailable
	}
	data, cid, err := s.fetch(ctx, viewer, r.ManifestCollection, "self", nil)
	if err != nil {
		return false, err
	}
	manifest, err := r.DecodeManifest(data, viewer)
	if err != nil {
		return false, err
	}
	generation, err := r.LoadRecords(ctx, manifest, viewer, 4096, 16*1024*1024, func(ctx context.Context, reference r.Reference) ([]byte, error) {
		key := reference.URI[strings.LastIndex(reference.URI, "/")+1:]
		data, _, err := s.fetch(ctx, viewer, r.ChunkCollection, key, &reference.CID)
		return data, err
	})
	if err != nil {
		return false, err
	}
	current, currentCID, err := s.fetch(ctx, viewer, r.ManifestCollection, "self", nil)
	if err != nil {
		return false, err
	}
	if cid != currentCID {
		return false, ErrStaleGeneration
	}
	if _, err := r.DecodeManifest(current, viewer); err != nil {
		return false, err
	}
	if err := s.activate(ctx, viewer, manifest, cid, data, generation); err != nil {
		return false, err
	}
	return true, nil
}

func revision(manifest r.Manifest) int64 {
	if manifest.Revision != nil {
		return *manifest.Revision
	}
	return manifest.LastSequence
}
func validateTransition(previous r.Manifest, previousCID string, candidate r.Manifest, candidateCID string) error {
	if previousCID == candidateCID {
		if !reflect.DeepEqual(previous, candidate) {
			return ErrStaleGeneration
		}
		return nil
	}
	if candidate.Version < previous.Version || candidate.LastSequence < previous.LastSequence || revision(candidate) <= revision(previous) || (candidate.Version == 1 && candidate.LastSequence == previous.LastSequence) {
		return ErrStaleGeneration
	}
	return nil
}

func (s *Store) activate(ctx context.Context, viewer string, manifest r.Manifest, cid string, data []byte, generation *r.Generation) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var previousJSON []byte
	var previousCID sql.NullString
	var ready bool
	if err := tx.QueryRowContext(ctx, `SELECT manifest::text, manifest_cid, projection_ready FROM appview_pds_read_state_authority WHERE viewer_did=$1 FOR UPDATE`, viewer).Scan(&previousJSON, &previousCID, &ready); err != nil {
		return err
	}
	// Workers reconcile an existing PDS authority; first migration belongs to the
	// explicit legacy parity protocol and cannot be inferred by this worker.
	if !previousCID.Valid {
		return ErrStaleGeneration
	}
	previous, err := r.DecodeManifest(previousJSON, viewer)
	if err != nil {
		return err
	}
	if err := validateTransition(previous, previousCID.String, manifest, cid); err != nil {
		return err
	}
	if !ready || previousCID.String != cid {
		if err := persistProjection(ctx, tx, viewer, generation.Projection.Operations()); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE appview_unread_counters SET dirty=TRUE WHERE viewer_did=$1 AND NOT dirty`, viewer); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE appview_pds_read_state_authority SET manifest=$2::jsonb,manifest_cid=$3,last_sequence=$4,manifest_revision=$5,activated_at=COALESCE(activated_at,NOW()),updated_at=NOW(),projection_ready=TRUE WHERE viewer_did=$1 AND (manifest_cid IS DISTINCT FROM $3 OR manifest IS DISTINCT FROM $2::jsonb OR NOT projection_ready)`, viewer, string(data), cid, manifest.LastSequence, revision(manifest)); err != nil {
		return err
	}
	return tx.Commit()
}
