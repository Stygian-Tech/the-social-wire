package thinappviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var ErrRecoveryYielded = errors.New("repository recovery yielded")

type RecoveryContext struct {
	Environment, SourceGeneration, RepoDID, WorkerID, LeaseToken string
	Sequence                                                     int64
	RequestID                                                    *string
}

func (c RecoveryContext) key() string {
	if c.RequestID != nil {
		return "request:" + *c.RequestID
	}
	return fmt.Sprintf("sync:%d", c.Sequence)
}

type SwiftDate struct{ time.Time }

func (d SwiftDate) MarshalJSON() ([]byte, error) {
	return json.Marshal(float64(d.UnixNano())/1e9 - 978307200)
}
func (d *SwiftDate) UnmarshalJSON(data []byte) error {
	var seconds float64
	if err := json.Unmarshal(data, &seconds); err != nil {
		return err
	}
	d.Time = time.Unix(0, int64((seconds+978307200)*1e9)).UTC()
	return nil
}

type RecoveryCollection struct {
	Cursor        *string  `json:"cursor,omitempty"`
	SeenCursors   []string `json:"seenCursors"`
	ObservedCount int      `json:"observedCount"`
	IndexedCount  int      `json:"indexedCount"`
	Complete      bool     `json:"complete"`
}
type RecoveryState struct {
	SnapshotMode    string                        `json:"snapshotMode,omitempty"`
	CommitCID       string                        `json:"commitCid,omitempty"`
	Revision        string                        `json:"revision,omitempty"`
	RecordOffset    int                           `json:"recordOffset,omitempty"`
	SnapshotID      string                        `json:"snapshotId"`
	PruningComplete bool                          `json:"pruningComplete"`
	PruneCreatedAt  *SwiftDate                    `json:"pruneCreatedAt,omitempty"`
	PruneURI        *string                       `json:"pruneURI,omitempty"`
	StartedAt       SwiftDate                     `json:"startedAt"`
	PDSBase         *string                       `json:"pdsBase,omitempty"`
	Collections     map[string]RecoveryCollection `json:"collections"`
	Completed       bool                          `json:"completed"`
}
type RecoveryStore struct{ DB *sql.DB }

func (s RecoveryStore) locked(ctx context.Context, tx *sql.Tx, c RecoveryContext) (*RecoveryState, error) {
	var raw *string
	var err error
	if c.RequestID != nil {
		err = tx.QueryRowContext(ctx, `SELECT recovery_state FROM appview_ingestion_reconciliation_requests WHERE environment=$1 AND source_generation=$2 AND id=$3 AND repo_did=$4 AND trigger_seq=$5 AND status='leased' AND lease_owner=$6 AND lease_token=$7 AND lease_expires_at>NOW() FOR UPDATE`, c.Environment, c.SourceGeneration, *c.RequestID, c.RepoDID, c.Sequence, c.WorkerID, c.LeaseToken).Scan(&raw)
	} else {
		err = tx.QueryRowContext(ctx, `SELECT recovery_state FROM appview_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND seq=$3 AND repo_did=$4 AND status='leased' AND lease_owner=$5 AND lease_token=$6 AND lease_expires_at>NOW() FOR UPDATE`, c.Environment, c.SourceGeneration, c.Sequence, c.RepoDID, c.WorkerID, c.LeaseToken).Scan(&raw)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrStaleInboxLease
	}
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, nil
	}
	var state RecoveryState
	if err := json.Unmarshal([]byte(*raw), &state); err != nil {
		return nil, err
	}
	return &state, nil
}
func (s RecoveryStore) write(ctx context.Context, tx *sql.Tx, c RecoveryContext, state RecoveryState) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if c.RequestID != nil {
		_, err = tx.ExecContext(ctx, "UPDATE appview_ingestion_reconciliation_requests SET recovery_state=$1 WHERE environment=$2 AND id=$3", string(raw), c.Environment, *c.RequestID)
	} else {
		_, err = tx.ExecContext(ctx, "UPDATE appview_ingestion_inbox SET recovery_state=$1 WHERE environment=$2 AND source_generation=$3 AND seq=$4", string(raw), c.Environment, c.SourceGeneration, c.Sequence)
	}
	return err
}
func (s RecoveryStore) Load(ctx context.Context, c RecoveryContext) (RecoveryState, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return RecoveryState{}, err
	}
	defer tx.Rollback()
	state, err := s.locked(ctx, tx, c)
	if err != nil {
		return RecoveryState{}, err
	}
	if state == nil {
		token, err := inboxLeaseToken()
		if err != nil {
			return RecoveryState{}, err
		}
		state = &RecoveryState{SnapshotID: token, StartedAt: SwiftDate{time.Now()}, Collections: map[string]RecoveryCollection{}}
		if err := s.write(ctx, tx, c, *state); err != nil {
			return RecoveryState{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return RecoveryState{}, err
	}
	return *state, nil
}
func (s RecoveryStore) Save(ctx context.Context, c RecoveryContext, state RecoveryState, observed []string, finish bool) (RecoveryState, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return state, err
	}
	defer tx.Rollback()
	previous, err := s.locked(ctx, tx, c)
	if err != nil {
		return state, err
	}
	if previous != nil && previous.Completed {
		if finish {
			return *previous, nil
		}
		return state, ErrStaleInboxLease
	}
	key := c.key() + ":" + state.SnapshotID
	if len(observed) > 0 {
		var syncSequence *int64
		if c.RequestID == nil {
			syncSequence = &c.Sequence
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO appview_repository_recovery_records(environment,source_generation,recovery_key,sync_sequence,request_id,uri) SELECT $1,$2,$3,$4,$5,uri FROM unnest($6::text[]) AS uri ON CONFLICT DO NOTHING`, c.Environment, c.SourceGeneration, key, syncSequence, c.RequestID, observed); err != nil {
			return state, err
		}
	}
	if finish {
		for _, collection := range []string{"site.standard.document", "site.standard.entry"} {
			if !state.Collections[collection].Complete {
				return state, ErrInvalidInboxRow
			}
		}
		if !state.PruningComplete {
			statement := `SELECT created_at,uri FROM content_items WHERE author_did=$1 ORDER BY created_at DESC,uri DESC LIMIT 1000`
			args := []any{c.RepoDID}
			if state.PruneCreatedAt != nil && state.PruneURI != nil {
				statement = `SELECT created_at,uri FROM content_items WHERE author_did=$1 AND(created_at,uri)<($2,$3)ORDER BY created_at DESC,uri DESC LIMIT 1000`
				args = append(args, state.PruneCreatedAt.Time, *state.PruneURI)
			}
			rows, err := tx.QueryContext(ctx, statement, args...)
			if err != nil {
				return state, err
			}
			candidates := []string{}
			for rows.Next() {
				var created time.Time
				var uri string
				if err := rows.Scan(&created, &uri); err != nil {
					rows.Close()
					return state, err
				}
				candidates = append(candidates, uri)
				state.PruneCreatedAt = &SwiftDate{created}
				copyURI := uri
				state.PruneURI = &copyURI
			}
			err = rows.Err()
			rows.Close()
			if err != nil {
				return state, err
			}
			if len(candidates) > 0 {
				if _, err := tx.ExecContext(ctx, `DELETE FROM content_items WHERE author_did=$1 AND indexed_at<=$2 AND uri=ANY($3::text[]) AND NOT EXISTS(SELECT 1 FROM appview_repository_recovery_records observed WHERE observed.environment=$4 AND observed.source_generation=$5 AND observed.recovery_key=$6 AND observed.uri=content_items.uri)`, c.RepoDID, state.StartedAt.Time, candidates, c.Environment, c.SourceGeneration, key); err != nil {
					return state, err
				}
			}
			state.PruningComplete = len(candidates) < 1000
		}
		state.Completed = false
		if state.PruningComplete {
			selector := "sync_sequence=$3"
			var selectorValue any = c.Sequence
			if c.RequestID != nil {
				selector = "request_id=$3"
				selectorValue = *c.RequestID
			}
			result, err := tx.ExecContext(ctx, `DELETE FROM appview_repository_recovery_records WHERE environment=$1 AND source_generation=$2 AND(recovery_key,uri)IN(SELECT recovery_key,uri FROM appview_repository_recovery_records WHERE environment=$1 AND source_generation=$2 AND `+selector+` ORDER BY recovery_key,uri LIMIT 1000)`, c.Environment, c.SourceGeneration, selectorValue)
			if err != nil {
				return state, err
			}
			count, err := result.RowsAffected()
			if err != nil {
				return state, err
			}
			state.Completed = count < 1000
		}
	}
	if err := s.write(ctx, tx, c, state); err != nil {
		return state, err
	}
	if err := tx.Commit(); err != nil {
		return state, err
	}
	return state, nil
}
func (s RecoveryStore) Yield(ctx context.Context, c RecoveryContext) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := s.locked(ctx, tx, c); err != nil {
		return err
	}
	at := time.Now()
	next := at.Add(250 * time.Millisecond)
	if c.RequestID != nil {
		_, err = tx.ExecContext(ctx, `UPDATE appview_ingestion_reconciliation_requests SET status='pending',next_attempt_at=$1,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,updated_at=$2 WHERE environment=$3 AND id=$4`, next, at, c.Environment, *c.RequestID)
	} else {
		_, err = tx.ExecContext(ctx, `UPDATE appview_ingestion_inbox SET status='retry',next_attempt_at=$1,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,failure_category=NULL,failure_reason=NULL,updated_at=$2 WHERE environment=$3 AND source_generation=$4 AND seq=$5`, next, at, c.Environment, c.SourceGeneration, c.Sequence)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}
