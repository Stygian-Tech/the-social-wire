package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"unicode/utf8"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

type poisonRecord struct {
	event  ingest.InboxEvent
	reason string
}

var ErrPoisonCapacityExceeded = errors.New("poison evidence capacity exhausted; operator review required")

const poisonMaxRecords = 10000
const poisonMaxPayloadBytes = 64 << 20

// Only deterministic payload representation failures enter quarantine. Database,
// admission, lease and transport errors retain their existing retry boundaries.
func preparePoisonRecords(events []ingest.InboxEvent) ([]ingest.InboxEvent, []poisonRecord) {
	prepared := make([]ingest.InboxEvent, 0, len(events))
	var poison []poisonRecord
	for _, event := range events {
		var payload []byte
		var err error
		if !utf8.Valid(event.Payload) {
			err = errors.New("payload is not UTF-8")
		} else {
			payload, err = normalizeWireJSONPayloadForPostgres(event.Payload)
		}
		if err != nil {
			reason := err.Error()
			if len(reason) > 512 {
				cut := 512
				for cut > 0 && !utf8.RuneStart(reason[cut]) {
					cut--
				}
				reason = reason[:cut]
			}
			poison = append(poison, poisonRecord{event: event, reason: reason})
			continue
		}
		event.Payload = payload
		prepared = append(prepared, event)
	}
	return prepared, poison
}

func (p *Postgres) stagePoisonRecords(ctx context.Context, tx *sql.Tx, poison []poisonRecord) error {
	if len(poison) > 0 {
		var valid bool
		if err := tx.QueryRowContext(ctx, `SELECT TRUE FROM ingestion_recovery_controllers WHERE environment=$1 AND source_generation=$2 FOR UPDATE`, p.source.Environment, p.source.Generation).Scan(&valid); err != nil {
			return err
		}
		var rows, retained int64
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*),COALESCE(SUM(OCTET_LENGTH(raw_payload)),0) FROM ingestion_poison_records WHERE environment=$1 AND source_generation=$2`, p.source.Environment, p.source.Generation).Scan(&rows, &retained); err != nil {
			return err
		}
		sequences := make([]uint64, 0, len(poison))
		for _, record := range poison {
			sequences = append(sequences, record.event.Seq)
		}
		encoded, _ := json.Marshal(sequences)
		existing, err := tx.QueryContext(ctx, `SELECT seq,payload_sha256,source_host FROM ingestion_poison_records WHERE environment=$1 AND source_generation=$2 AND seq IN(SELECT jsonb_array_elements_text($3::jsonb)::bigint)`, p.source.Environment, p.source.Generation, string(encoded))
		if err != nil {
			return err
		}
		seen := make(map[uint64]string, len(poison))
		for existing.Next() {
			var seq uint64
			var digest, host string
			if err := existing.Scan(&seq, &digest, &host); err != nil {
				existing.Close()
				return err
			}
			if host != p.source.Host {
				existing.Close()
				return ErrSourceDiscontinuity
			}
			seen[seq] = digest
		}
		if err := existing.Err(); err != nil {
			existing.Close()
			return err
		}
		existing.Close()
		var incoming, incomingRows int64
		for _, record := range poison {
			digest := sha256.Sum256(record.event.Payload)
			key := hex.EncodeToString(digest[:])
			if prior, found := seen[record.event.Seq]; found {
				if prior != key {
					return ErrSourceDiscontinuity
				}
				continue
			}
			seen[record.event.Seq] = key
			incoming += int64(len(record.event.Payload))
			incomingRows++
		}
		if rows+incomingRows > poisonMaxRecords || retained+incoming > poisonMaxPayloadBytes {
			return ErrPoisonCapacityExceeded
		}
	}
	for _, record := range poison {
		event := record.event
		digest := sha256.Sum256(event.Payload)
		result, err := tx.ExecContext(ctx, `INSERT INTO ingestion_poison_records(environment,source_generation,seq,source_host,repo_did,collection,record_key,record_cid,payload_sha256,raw_payload,reason) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT(environment,source_generation,seq) DO UPDATE SET updated_at=NOW() WHERE ingestion_poison_records.payload_sha256=EXCLUDED.payload_sha256 AND ingestion_poison_records.source_host=EXCLUDED.source_host`, p.source.Environment, p.source.Generation, int64(event.Seq), p.source.Host, event.RepoDID, event.Collection, event.RecordKey, event.RecordCID, hex.EncodeToString(digest[:]), event.Payload, record.reason)
		if err != nil {
			return fmt.Errorf("quarantine poison event %d: %w", event.Seq, err)
		}
		n, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if n != 1 {
			return fmt.Errorf("quarantine identity collision at seq %d: %w", event.Seq, ErrSourceDiscontinuity)
		}
	}
	if len(poison) > 0 {
		_, err := tx.ExecContext(ctx, `UPDATE ingestion_recovery_controllers SET status='degraded',last_error='Deterministic poison record quarantined',updated_at=NOW() WHERE environment=$1 AND source_generation=$2 AND status<>'blocked_discontinuity'`, p.source.Environment, p.source.Generation)
		return err
	}
	return nil
}

// Keep source/CID/hash evidence after raw bytes reach the seven-day retention
// boundary. Expiry never turns unresolved poison into successful coverage.
func (p *Postgres) PrunePoisonPayloads(ctx context.Context) error {
	_, err := p.db.ExecContext(ctx, `WITH expired AS(SELECT environment,source_generation,seq FROM ingestion_poison_records WHERE environment=$1 AND source_generation=$2 AND status='quarantined' AND expires_at<=NOW() ORDER BY seq FOR UPDATE SKIP LOCKED LIMIT 500) UPDATE ingestion_poison_records poison SET raw_payload=NULL,status='expired',updated_at=NOW() FROM expired WHERE poison.environment=expired.environment AND poison.source_generation=expired.source_generation AND poison.seq=expired.seq`, p.source.Environment, p.source.Generation)
	return err
}
