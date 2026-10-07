package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestOperationsStreamEvidenceAndHeartbeatIsolation(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, _ := NewPostgresStore(tx, "dev")
	at := time.Now().UTC().Truncate(time.Microsecond)
	fixture, _ := randomUUID()
	if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_stream_state(environment,source,connection_state,last_received_cursor,last_committed_cursor,queue_depth,queue_capacity,queue_overflow_total,queue_observed_at,heartbeat_at,version) VALUES('dev',$1,'connected',9007199254740993,9007199254740992,3,100,2,$2,$2,7)`, fixture, at); err != nil {
		t.Fatal(err)
	}
	state, err := store.FetchStreamState(ctx, fixture)
	if err != nil || state == nil || state.LastReceivedCursor == nil || *state.LastReceivedCursor != 9007199254740993 || state.QueueEvidence == nil || state.QueueEvidence.Accuracy != "exact" || state.QueueEvidence.Source != fixture+"_transport_queue" || !state.QueueEvidence.ValidUntil.Equal(at.Add(15*time.Second)) {
		t.Fatal(state, err)
	}
	if absent, err := store.FetchStreamState(ctx, fixture+"absent"); err != nil || absent != nil {
		t.Fatal(absent, err)
	}
	heartbeat := ServiceState{Service: "operations", Environment: "dev", InstanceID: fixture, Liveness: "healthy", Readiness: "healthy", Freshness: "healthy", Completeness: "healthy", StartedAt: at, HeartbeatAt: at, DependencyState: map[string]string{"operations_store": "ready"}}
	if err = store.UpsertServiceState(ctx, heartbeat); err != nil {
		t.Fatal(err)
	}
	heartbeat.Environment = "prod"
	if err = store.UpsertServiceState(ctx, heartbeat); !errors.Is(err, ErrEnvironmentMismatch) {
		t.Fatal("heartbeat escaped scope", err)
	}
	heartbeat.Environment = "dev"
	heartbeat.Service = "coordinator-appview"
	if err = store.UpsertServiceState(ctx, heartbeat); !errors.Is(err, ErrLeaseConflict) {
		t.Fatal("unfenced coordinator heartbeat accepted", err)
	}
	for _, id := range []string{fixture + "a", fixture + "b"} {
		if _, err = tx.Exec(ctx, `INSERT INTO appview_jetstream_endpoints(environment,id,display_name,host,role,connection_state,updated_at) VALUES('dev',$1,'fixture','fixture.invalid','standby','unknown',$2)`, id, at); err != nil {
			t.Fatal(err)
		}
	}
	// Narrow the fixture transaction so equal-time ordering is independent of unrelated retained endpoints.
	if _, err = tx.Exec(ctx, `DELETE FROM appview_jetstream_endpoints WHERE environment='dev' AND id!=$1 AND id!=$2`, fixture+"a", fixture+"b"); err != nil {
		t.Fatal(err)
	}
	endpoints, err := store.ListJetstreamEndpoints(ctx, 1, nil)
	if err != nil || endpoints.TotalCount != 2 || endpoints.NextCursor == nil || endpoints.Items[0].ID != fixture+"b" {
		t.Fatal(endpoints, err)
	}
	next, err := store.ListJetstreamEndpoints(ctx, 1, endpoints.NextCursor)
	if err != nil || len(next.Items) != 1 || next.Items[0].ID != fixture+"a" {
		t.Fatal(next, err)
	}
	counts, err := store.LifecycleCounts(ctx)
	if err != nil || counts.ActiveGaps < 0 || counts.AttentionBackfills < 0 {
		t.Fatal(counts, err)
	}
}
