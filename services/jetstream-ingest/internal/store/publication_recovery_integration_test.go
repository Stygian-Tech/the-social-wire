package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestPublicationRecoveryRegistrationIsAtomicWithCrashRewind(t *testing.T) {
	url := os.Getenv("JETSTREAM_INGEST_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("JETSTREAM_INGEST_TEST_DATABASE_URL is not set")
	}
	for _, mismatch := range []bool{false, true} {
		t.Run(fmt.Sprintf("identity_mismatch_%t", mismatch), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			db, err := sql.Open("pgx", url)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			environment := fmt.Sprintf("publication-recovery-%d", time.Now().UnixNano())
			source := ingest.SourceIdentity{PipelineMode: config.WirePipelineMode, Environment: environment,
				Generation: "live", Host: "jetstream.example.test", StreamNSID: "network.bsky.jetstream.subscribeEvents",
				FilterFingerprint: environment, CursorKind: "jetstream_v2_seq"}
			store := New(db, source)
			lease, err := store.AcquireLease(ctx, "publication-recovery", "fixture", time.Minute)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				for _, table := range []string{"wire_publication_signal_recovery_jobs", "wire_ingestion_inbox_epochs", "wire_ingestion_recovery_anchors", "appview_jetstream_checkpoints", "wire_ingestion_admission", "appview_ingestion_leases"} {
					_, _ = db.ExecContext(context.Background(), "DELETE FROM "+table+" WHERE environment=$1", environment)
				}
			}()
			host := source.Host
			if mismatch {
				host = "other.example.test"
			}
			_, err = db.ExecContext(ctx, `INSERT INTO appview_jetstream_checkpoints
				(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,replay_state)
				VALUES($1,'live',$2,$3,$4,'jetstream_v2_seq',400,'live')`, environment, host, source.StreamNSID, source.FilterFingerprint)
			if err != nil {
				t.Fatal(err)
			}
			_, err = db.ExecContext(ctx, `INSERT INTO wire_ingestion_admission(environment,retained_rows,updated_at) VALUES($1,0,NOW())`, environment)
			if err != nil {
				t.Fatal(err)
			}
			_, err = db.ExecContext(ctx, `INSERT INTO wire_ingestion_recovery_anchors(environment,source_generation,anchor_bucket,checkpoint_seq,checkpoint_event_time,captured_at)
				VALUES($1,'live',date_trunc('hour',NOW()),100,NOW()-interval '7 days',NOW())`, environment)
			if err != nil {
				t.Fatal(err)
			}
			recovered, err := store.ReconcileWireAdmission(ctx, lease)
			if mismatch {
				if err == nil || recovered {
					t.Fatal("identity mismatch did not reject recovery")
				}
			} else if err != nil || !recovered {
				t.Fatalf("recovery failed: %v", err)
			}
			var jobs int
			var staged int64
			if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM wire_publication_signal_recovery_jobs WHERE environment=$1 AND maximum_source_seq=400`, environment).Scan(&jobs); err != nil {
				t.Fatal(err)
			}
			if err := db.QueryRowContext(ctx, `SELECT last_staged_seq FROM appview_jetstream_checkpoints WHERE environment=$1`, environment).Scan(&staged); err != nil {
				t.Fatal(err)
			}
			if mismatch {
				if jobs != 0 || staged != 400 {
					t.Fatalf("failed rewind leaked state: jobs=%d cursor=%d", jobs, staged)
				}
			} else {
				if jobs != 1 || staged != 100 {
					t.Fatalf("wrong recovery boundary: jobs=%d cursor=%d", jobs, staged)
				}
				again, err := store.ReconcileWireAdmission(ctx, lease)
				if err != nil || again {
					t.Fatalf("existing epoch repeated recovery: %v", err)
				}
			}
		})
	}
}
