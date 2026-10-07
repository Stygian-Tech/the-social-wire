package pdsreadstatecore

import (
	"context"
	"database/sql"
	"encoding/json"

	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

type Status struct {
	Authority       string      `json:"authority"`
	MigrationState  string      `json:"migrationState"`
	LegacyRevision  int64       `json:"legacyRevision"`
	Manifest        *r.Manifest `json:"manifest,omitempty"`
	ManifestCID     *string     `json:"manifestCid,omitempty"`
	ProjectionReady bool        `json:"projectionReady"`
}

func (s *Store) Status(ctx context.Context, viewer string) (Status, error) {
	status := Status{Authority: "appview", MigrationState: "notStarted", ProjectionReady: true}
	var data []byte
	var cid sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT legacy_revision,manifest::text,manifest_cid,projection_ready FROM appview_pds_read_state_authority WHERE viewer_did=$1`, viewer).Scan(&status.LegacyRevision, &data, &cid, &status.ProjectionReady)
	if err == sql.ErrNoRows {
		return status, nil
	}
	if err != nil {
		return Status{}, err
	}
	if cid.Valid {
		var manifest r.Manifest
		if err := json.Unmarshal(data, &manifest); err != nil {
			return Status{}, err
		}
		status.Authority, status.MigrationState = "pds", "verified"
		status.Manifest, status.ManifestCID = &manifest, &cid.String
	}
	return status, nil
}
