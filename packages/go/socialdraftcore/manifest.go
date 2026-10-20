package socialdraftcore

import (
	"context"
	"database/sql"
	"strings"
	"unicode/utf8"
)

func (s *Service) manifest(ctx context.Context, tx *transaction, owner, id string) (Manifest, error) {
	m := Manifest{DraftID: id, Attachments: []AssetBinding{}}
	e := tx.QueryRowContext(ctx, `SELECT revision,deleted FROM private_social_draft_manifests WHERE owner=$1 AND draft_id=$2`, owner, id).Scan(&m.Revision, &m.Deleted)
	if e == sql.ErrNoRows {
		return m, ErrNotFound
	}
	if e != nil {
		return m, e
	}
	if m.Deleted {
		return m, nil
	}
	rows, e := tx.QueryContext(ctx, `SELECT asset_id::text,role,ref FROM private_social_draft_bindings WHERE owner=$1 AND draft_id=$2 ORDER BY position`, owner, id)
	if e != nil {
		return m, e
	}
	var bindings []AssetBinding
	for rows.Next() {
		var b AssetBinding
		if e = rows.Scan(&b.AssetID, &b.Role, &b.Ref); e != nil {
			rows.Close()
			return m, e
		}
		bindings = append(bindings, b)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return m, e
	}
	for _, b := range bindings {
		b.Asset, _, e = s.asset(ctx, tx, owner, b.AssetID)
		if e != nil {
			return m, e
		}
		m.Attachments = append(m.Attachments, b)
	}
	return m, nil
}
func (s *Service) Manifest(ctx context.Context, owner, draftID string) (Manifest, error) {
	if e := s.available(); e != nil {
		return Manifest{}, e
	}
	if !tidPattern.MatchString(draftID) {
		return Manifest{}, ErrInvalid
	}
	tx, e := s.begin(ctx, owner)
	if e != nil {
		return Manifest{}, e
	}
	defer tx.Rollback()
	m, e := s.manifest(ctx, tx, owner, draftID)
	if e != nil {
		return m, e
	}
	return m, tx.Commit()
}
func validRefs(refs []ManifestRef) bool {
	if len(refs) > MaxManifestRefs {
		return false
	}
	seen := map[ManifestRef]bool{}
	for _, r := range refs {
		if !uuidPattern.MatchString(r.AssetID) || !utf8.ValidString(r.Ref) || strings.ContainsRune(r.Ref, 0) || len(r.Ref) > 512 || seen[r] {
			return false
		}
		switch r.Role {
		case "original", "prepared", "video", "poster", "caption", "gif":
		default:
			return false
		}
		seen[r] = true
	}
	return true
}
func (s *Service) PutManifest(ctx context.Context, owner string, in PutManifestInput) (Manifest, error) {
	return s.mutateManifest(ctx, owner, in, false)
}
func (s *Service) DeleteManifest(ctx context.Context, owner, draftID string, expectedRevision int64) (Manifest, error) {
	return s.mutateManifest(ctx, owner, PutManifestInput{DraftID: draftID, ExpectedRevision: expectedRevision}, true)
}
func (s *Service) mutateManifest(ctx context.Context, owner string, in PutManifestInput, deleted bool) (Manifest, error) {
	if e := s.available(); e != nil {
		return Manifest{}, e
	}
	if !tidPattern.MatchString(in.DraftID) || in.ExpectedRevision < 0 || in.ExpectedRevision == int64(^uint64(0)>>1) || !validRefs(in.Attachments) {
		return Manifest{}, ErrInvalid
	}
	tx, e := s.begin(ctx, owner)
	if e != nil {
		return Manifest{}, e
	}
	defer tx.Rollback()
	m, e := s.manifest(ctx, tx, owner, in.DraftID)
	if e != nil && e != ErrNotFound {
		return Manifest{}, e
	}
	if m.Revision != in.ExpectedRevision {
		return Manifest{}, ErrConflict
	}
	for _, r := range in.Attachments {
		a, _, e := s.asset(ctx, tx, owner, r.AssetID)
		if e != nil {
			return Manifest{}, e
		}
		if a.State != "ready" {
			return Manifest{}, ErrUploadPending
		}
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_manifests(owner,draft_id,revision,deleted) VALUES($1,$2,$3,$4) ON CONFLICT(owner,draft_id) DO UPDATE SET revision=EXCLUDED.revision,deleted=EXCLUDED.deleted`, owner, in.DraftID, in.ExpectedRevision+1, deleted); e != nil {
		return Manifest{}, e
	}
	if _, e = tx.ExecContext(ctx, `DELETE FROM private_social_draft_bindings WHERE owner=$1 AND draft_id=$2`, owner, in.DraftID); e != nil {
		return Manifest{}, e
	}
	for i, r := range in.Attachments {
		if _, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_bindings(owner,draft_id,position,asset_id,role,ref) VALUES($1,$2,$3,$4,$5,$6)`, owner, in.DraftID, i, r.AssetID, r.Role, r.Ref); e != nil {
			return Manifest{}, e
		}
	}
	// Referenced assets have no expiry job. Final detach recreates an immediate
	// durable deletion job, rather than GC revisiting live assets forever.
	for _, r := range in.Attachments {
		if _, e = tx.ExecContext(ctx, `DELETE FROM private_social_draft_cleanup WHERE owner=$1 AND asset_id=$2`, owner, r.AssetID); e != nil {
			return Manifest{}, e
		}
	}
	// Removed attachments become inaccessible immediately, unless another draft
	// still references them. Physical deletion remains a durable retryable job.
	for _, old := range m.Attachments {
		var referenced bool
		if e = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM private_social_draft_bindings WHERE owner=$1 AND asset_id=$2)`, owner, old.AssetID).Scan(&referenced); e != nil {
			return Manifest{}, e
		}
		if !referenced {
			if _, e = tx.ExecContext(ctx, `UPDATE private_social_draft_assets SET state='deleted' WHERE owner=$1 AND asset_id=$2`, owner, old.AssetID); e != nil {
				return Manifest{}, e
			}
			if _, e = tx.ExecContext(ctx, `INSERT INTO private_social_draft_cleanup(owner,asset_id,available_at) VALUES($1,$2,now()) ON CONFLICT(owner,asset_id) DO UPDATE SET available_at=now(),attempts=0`, owner, old.AssetID); e != nil {
				return Manifest{}, e
			}
		}
	}
	result, e := s.manifest(ctx, tx, owner, in.DraftID)
	if e != nil {
		return result, e
	}
	return result, tx.Commit()
}
