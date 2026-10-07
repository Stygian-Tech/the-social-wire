package wireworkercore

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

type RecordOrder string

const (
	RecordOlder    RecordOrder = "older"
	RecordSame     RecordOrder = "same"
	RecordNewer    RecordOrder = "newer"
	RecordConflict RecordOrder = "conflict"
)

// StandardRecordFence is logged evidence. Snapshot observations are repository
// watermarks, not fresh publication activity and not comparable transport sequences.
type StandardRecordFence struct {
	Generation                      string
	Sequence                        int64
	Host, Cursor, Kind, Operation   string
	Revision, ObservedRevision, CID sql.NullString
	Time                            time.Time
	ActivityRecorded                bool
}

func NewStandardRecordFence(event InboxEvent, revision, cid sql.NullString) StandardRecordFence {
	f := StandardRecordFence{Generation: event.Repository.SourceGeneration, Sequence: event.Sequence, Host: event.SourceHost, Cursor: event.CursorKind, Kind: event.EventKind, Operation: event.Operation.String, Revision: revision, CID: cid, Time: event.EventTime}
	if !event.Operation.Valid {
		f.Operation = "update"
	}
	if event.EventKind == "snapshot" {
		f.ObservedRevision = revision
	}
	return f
}
func ValidRecordRevision(value string) bool {
	if len(value) != 13 {
		return false
	}
	for _, c := range value {
		if !strings.ContainsRune("234567abcdefghijklmnopqrstuvwxyz", c) {
			return false
		}
	}
	return true
}
func (f StandardRecordFence) Compare(current StandardRecordFence) RecordOrder {
	sameTransport := f.Kind == "commit" && current.Kind == "commit" && f.Host == current.Host && f.Cursor == current.Cursor && f.Sequence == current.Sequence
	sameCID := f.CID.Valid && current.CID.Valid && f.CID.String == current.CID.String
	sameValue := (f.Operation == "delete") == (current.Operation == "delete") && (f.Operation == "delete" || sameCID || sameTransport && !f.CID.Valid && !current.CID.Valid && f.Operation == current.Operation)
	var known string
	for _, v := range []sql.NullString{current.Revision, current.ObservedRevision} {
		if v.Valid && ValidRecordRevision(v.String) && v.String > known {
			known = v.String
		}
	}
	if f.Revision.Valid && ValidRecordRevision(f.Revision.String) && known != "" {
		if sameValue && f.CID.Valid && (f.Kind == "snapshot" || (current.Kind == "snapshot" || current.ObservedRevision.Valid) && f.Revision.String <= known) {
			return RecordSame
		}
		if f.Revision.String != known {
			if f.Revision.String > known {
				return RecordNewer
			}
			return RecordOlder
		}
		if sameValue {
			return RecordSame
		}
		return RecordConflict
	}
	if f.Kind == "commit" && current.Kind == "commit" && !current.ObservedRevision.Valid && f.Host == current.Host && f.Cursor == current.Cursor {
		if f.Sequence != current.Sequence {
			if f.Sequence > current.Sequence {
				return RecordNewer
			}
			return RecordOlder
		}
		if sameValue && f.Revision == current.Revision {
			return RecordSame
		}
	}
	return RecordConflict
}
func (f StandardRecordFence) Observing(revision sql.NullString) StandardRecordFence {
	for _, v := range []sql.NullString{f.ObservedRevision, revision} {
		if v.Valid && ValidRecordRevision(v.String) && (!f.ObservedRevision.Valid || v.String > f.ObservedRevision.String) {
			f.ObservedRevision = v
		}
	}
	return f
}
func LoadStandardRecordFence(ctx context.Context, tx *sql.Tx, event InboxEvent) (*StandardRecordFence, error) {
	var f StandardRecordFence
	err := tx.QueryRowContext(ctx, `SELECT source_generation,seq,source_host,cursor_kind,event_kind,operation,repo_rev,record_cid,event_time,activity_recorded,observed_repo_rev FROM wire_standard_record_fences WHERE environment=$1 AND source_uri=$2`, event.Repository.Environment, event.SourceURI()).Scan(&f.Generation, &f.Sequence, &f.Host, &f.Cursor, &f.Kind, &f.Operation, &f.Revision, &f.CID, &f.Time, &f.ActivityRecorded, &f.ObservedRevision)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &f, nil
}
func (f StandardRecordFence) Save(ctx context.Context, tx *sql.Tx, event InboxEvent, at time.Time) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO wire_standard_record_fences(environment,source_uri,source_generation,seq,source_host,cursor_kind,event_kind,operation,repo_rev,observed_repo_rev,record_cid,event_time,activity_recorded,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) ON CONFLICT(environment,source_uri) DO UPDATE SET source_generation=EXCLUDED.source_generation,seq=EXCLUDED.seq,source_host=EXCLUDED.source_host,cursor_kind=EXCLUDED.cursor_kind,event_kind=EXCLUDED.event_kind,operation=EXCLUDED.operation,repo_rev=EXCLUDED.repo_rev,observed_repo_rev=EXCLUDED.observed_repo_rev,record_cid=EXCLUDED.record_cid,event_time=EXCLUDED.event_time,activity_recorded=EXCLUDED.activity_recorded,updated_at=EXCLUDED.updated_at WHERE(wire_standard_record_fences.source_generation,wire_standard_record_fences.seq,wire_standard_record_fences.repo_rev,wire_standard_record_fences.observed_repo_rev,wire_standard_record_fences.activity_recorded)IS DISTINCT FROM(EXCLUDED.source_generation,EXCLUDED.seq,EXCLUDED.repo_rev,EXCLUDED.observed_repo_rev,EXCLUDED.activity_recorded)`, event.Repository.Environment, event.SourceURI(), f.Generation, f.Sequence, f.Host, f.Cursor, f.Kind, f.Operation, f.Revision, f.ObservedRevision, f.CID, f.Time, f.ActivityRecorded, at)
	return err
}
