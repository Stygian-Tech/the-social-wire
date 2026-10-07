package operationsapi

import (
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestOverviewDoesNotInventDatabaseEvidenceOrPopulateRetiredLists(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	store, _ := NewPostgresStore(pool, "dev")
	at := time.Now().UTC()
	capabilities := Capabilities{Environment: "dev"}
	overview, err := store.Overview(ctx, at, &capabilities)
	if err != nil {
		t.Fatal(err)
	}
	if overview.Database != nil || overview.Evidence["database"].Accuracy != "unavailable" || overview.Evidence["database"].DegradedReason == nil || overview.Capabilities != &capabilities || overview.Viewers == nil || overview.Durability == nil {
		t.Fatal(overview)
	}
	raw, err := json.Marshal(overview)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]json.RawMessage
	if err = json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"jetstreamEndpoints", "commands", "gaps", "backfills", "alerts", "recentTraces", "metricRollups"} {
		if string(payload[key]) != "[]" {
			t.Fatal(key, string(payload[key]))
		}
	}
}
