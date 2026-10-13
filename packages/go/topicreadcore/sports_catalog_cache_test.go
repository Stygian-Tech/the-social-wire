package topicreadcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func TestSportsCatalogCacheLeaseMutationAndInactiveParity(t *testing.T) {
	now := time.Now().UTC()
	active := sportscore.Entity{ID: "team", Name: "Team", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}
	inactive := active
	inactive.ID = "retired"
	inactive.Active = false
	full := []sportscore.Entity{active, inactive}
	revision, _ := sportscore.ServingCatalogRevision(full)
	serving, _ := sportscore.ServingCatalogRevision([]sportscore.Entity{active})
	state := &catalogLeaseConnector{version: "v1", generated: now}
	db := sql.OpenDB(state)
	defer db.Close()
	store := &SportsStore{DB: db}
	store.catalogCache = &sportsPageCatalogCache{version: "v1", generated: now, fullRevision: revision, revision: serving, entities: []sportscore.Entity{active}}
	for range 3 {
		value, err := store.Catalog(context.Background())
		if err != nil || len(value) != 1 || value[0].ID != "team" {
			t.Fatal(value, err)
		}
		current, _ := store.servingCatalogRevision(value)
		cold, _ := sportscore.ServingCatalogRevision([]sportscore.Entity{active})
		if current != cold {
			t.Fatal("inactive transport changed existing cursor revision")
		}
	}
	if state.queries != 3 {
		t.Fatal("warm catalog must only acquire immutable lease", state.queries)
	}
	active.Name = "Changed"
	raw, _ := corpuscore.MarshalHTTP([]sportscore.Entity{active})
	state.version = "v2"
	state.generated = now.Add(time.Second)
	state.payload = string(raw)
	changed, err := store.Catalog(context.Background())
	if err != nil || changed[0].Name != "Changed" {
		t.Fatal(changed, err)
	}
	changedRevision, _ := store.servingCatalogRevision(changed)
	if changedRevision == serving {
		t.Fatal("catalog mutation skipped fingerprint")
	}
	queries := state.queries
	if _, err := store.Catalog(context.Background()); err != nil || state.queries != queries+1 {
		t.Fatal("changed catalog should become warm", state.queries, err)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.Catalog(cancelled); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled lease reused cache", err)
	}
}

type catalogLeaseConnector struct {
	version   string
	generated time.Time
	payload   string
	queries   int
}

func (s *catalogLeaseConnector) Connect(context.Context) (driver.Conn, error) {
	return &catalogLeaseConn{s}, nil
}
func (s *catalogLeaseConnector) Driver() driver.Driver { return reuseDriver{} }

type catalogLeaseConn struct{ state *catalogLeaseConnector }

func (*catalogLeaseConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (*catalogLeaseConn) Close() error              { return nil }
func (*catalogLeaseConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected transaction") }
func (c *catalogLeaseConn) QueryContext(ctx context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.state.queries++
	if !strings.Contains(query, "SELECT entities::text") && strings.Contains(query, "wire_serving.sports_catalog") {
		return &reuseRows{columns: []string{"version", "generated"}, row: []driver.Value{c.state.version, c.state.generated}}, nil
	}
	return &reuseRows{columns: []string{"payload"}, row: []driver.Value{c.state.payload}}, nil
}

func TestPostgresSportsCanonicalCatalogLeaseAndReplicaCursorParity(t *testing.T) {
	db := selectionDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	id := "99999999-3333-3333-3333-333333333333"
	active := sportscore.Entity{ID: "canonical-team", Name: "Canonical Team", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}
	retired := active
	retired.ID = "canonical-retired"
	retired.Active = false
	full := []sportscore.Entity{active, retired}
	raw, _ := json.Marshal(map[string]any{"entities": full})
	t.Cleanup(func() { db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, id) })
	if _, err := db.Exec(`INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1::uuid,'canonical-v1',$2,$3::jsonb,TRUE)`, id, now, string(raw)); err != nil {
		t.Fatal(err)
	}
	fullRevision, _ := sportscore.ServingCatalogRevision(full)
	servingRevision, _ := sportscore.ServingCatalogRevision([]sportscore.Entity{active})
	source := corpuscore.SportsGeneration{CatalogVersion: "canonical-v1", CatalogGeneratedAt: now, CatalogRevision: fullRevision, ServingCatalogRevision: servingRevision}
	warm := &SportsStore{DB: db}
	cold := &SportsStore{DB: db}
	for _, store := range []*SportsStore{warm, cold} {
		if err := store.requireSourceCatalog(context.Background(), source); err != nil {
			t.Fatal(err)
		}
		catalog, err := store.Catalog(context.Background())
		if err != nil || len(catalog) != 1 || !catalog[0].Active {
			t.Fatal(catalog, err)
		}
		revision, _ := store.servingCatalogRevision(catalog)
		if revision != servingRevision {
			t.Fatal("active catalog cursor fingerprint differs by cache warmth")
		}
	}
	codec, err := NewTopicCursorCodec([]byte(strings.Repeat("s", 32)))
	if err != nil {
		t.Fatal(err)
	}
	token, err := codec.Encode(TopicCursor{Feed: "sports", GenerationID: id, Language: "en", PreferenceFingerprint: servingRevision, ViewerScope: "viewer", NextOrdinal: 30, ExpiresAt: topicExpiry(now.Add(time.Hour))})
	if err != nil {
		t.Fatal(err)
	}
	coldCatalog, _ := cold.Catalog(context.Background())
	coldRevision, _ := cold.servingCatalogRevision(coldCatalog)
	if decoded, err := codec.Decode(token, "en", coldRevision, "viewer", "sports", now); err != nil || decoded.NextOrdinal != 30 {
		t.Fatal("cold replica cannot continue warm cursor", decoded, err)
	}
	missing := source
	missing.CatalogVersion = "absent"
	if err := (&SportsStore{DB: db}).requireSourceCatalog(context.Background(), missing); !errors.Is(err, ErrUnavailable) {
		t.Fatal("missing authoritative catalog accepted", err)
	}
	mismatch := source
	mismatch.CatalogRevision = strings.Repeat("a", 64)
	if err := (&SportsStore{DB: db}).requireSourceCatalog(context.Background(), mismatch); !errors.Is(err, ErrUnavailable) {
		t.Fatal("mismatched fingerprint accepted", err)
	}
	active.Name = "Current"
	full[0] = active
	raw, _ = json.Marshal(map[string]any{"entities": full})
	if _, err := db.Exec(`UPDATE sports_catalog_snapshots SET version='canonical-v2',generated_at=$2,payload=$3::jsonb WHERE snapshot_id=$1::uuid`, id, now.Add(time.Second), string(raw)); err != nil {
		t.Fatal(err)
	}
	current, err := warm.Catalog(context.Background())
	if err != nil || current[0].Name != "Current" {
		t.Fatal("warm catalog skipped new authoritative lease", current, err)
	}
	currentRevision, _ := warm.servingCatalogRevision(current)
	if _, err := codec.Decode(token, "en", currentRevision, "viewer", "sports", now); !errors.Is(err, ErrInvalidCursor) {
		t.Fatal("changed catalog reused old cursor fingerprint", err)
	}
	if _, err := db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := warm.Catalog(context.Background()); !errors.Is(err, ErrUnavailable) {
		t.Fatal("missing catalog lease fell back to stale projection", err)
	}

}
