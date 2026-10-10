package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"regexp"
	"testing"
	"time"
)

// Rollup publication and tracking are database-wide. These fixtures deliberately
// remain serial (go test -p 1; no t.Parallel) and require a loopback disposable
// migrated database. CI already runs the shared database package suite with -p 1.
type rollupFixture struct {
	t      *testing.T
	db     *sql.DB
	at     time.Time
	prefix string
	store  PostgresSignalRollupStore
}

func newRollupFixture(t *testing.T, incremental bool) *rollupFixture {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL to a loopback disposable database")
	}
	if err := validateRollupFixtureDSN(dsn); err != nil {
		t.Fatal(err)
	}
	db := generationDatabase(t)
	id, err := newGenerationID()
	if err != nil {
		t.Fatal(err)
	}
	f := &rollupFixture{t: t, db: db, at: time.Now().UTC().Truncate(time.Second), prefix: "rollup-go-" + id, store: PostgresSignalRollupStore{DB: db, IncrementalEnabled: incremental}}
	f.exec(`SELECT wire_set_signal_rollup_tracking($1)`, incremental)
	t.Cleanup(func() {
		if _, err := db.Exec(`SELECT wire_set_signal_rollup_tracking(false)`); err != nil {
			t.Error(err)
		}
		for _, table := range []string{"wire_signal_events", "wire_article_feedback", "wire_signal_rollup_dirty", "wire_signal_rollup_schedule", "wire_signal_rollups", "wire_items"} {
			if _, err := db.Exec(`DELETE FROM `+table+` WHERE canonical_key LIKE $1`, f.prefix+"%"); err != nil {
				t.Error(err)
			}
		}
	})
	return f
}
func (f *rollupFixture) exec(query string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(query, args...); err != nil {
		f.t.Fatal(err)
	}
}
func (f *rollupFixture) item(suffix string) string {
	f.t.Helper()
	key := f.prefix + "-" + suffix
	f.exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)VALUES($1,$2,'fixture.example','Fixture','Rollup',$3,$3,$4)`, key, "https://fixture.example/"+key, f.at, f.at.Add(14*24*time.Hour))
	return key
}
func (f *rollupFixture) signal(key, suffix string, occurred, expires time.Time) {
	f.t.Helper()
	f.exec(`SELECT ensure_wire_signal_event_partition($1::date)`, occurred)
	f.insertSignal(key, suffix, occurred, expires)
}
func (f *rollupFixture) insertSignal(key, suffix string, occurred, expires time.Time) {
	f.t.Helper()
	event := f.prefix + "-event-" + suffix
	f.exec(`INSERT INTO wire_signal_events(event_key,canonical_key,signal_kind,actor_key_hash,source_uri,occurred_at,expires_at,source_collection,source_action)VALUES($1,$2,'share',$3,$4,$5,$6,'app.bsky.feed.post','share')`, event, key, "actor-hash-"+event, "at://did:example:fixture/app.bsky.feed.post/"+event, occurred, expires)
}
func (f *rollupFixture) refresh(at time.Time) {
	f.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := f.store.Refresh(ctx, at); err != nil {
		f.t.Fatal(err)
	}
}
func (f *rollupFixture) snapshot(key string, physical bool) string {
	f.t.Helper()
	query := `SELECT (to_jsonb(r)-'updated_at')::text FROM wire_signal_rollups r WHERE canonical_key=$1`
	if physical {
		query = `SELECT jsonb_build_object('row',to_jsonb(r),'tuple',ctid::text,'transaction',xmin::text)::text FROM wire_signal_rollups r WHERE canonical_key=$1`
	}
	var result string
	err := f.db.QueryRow(query, key).Scan(&result)
	if err == sql.ErrNoRows {
		return ""
	}
	if err != nil {
		f.t.Fatal(err)
	}
	return result
}
func (f *rollupFixture) count(key, column string) int {
	f.t.Helper()
	values := map[string]any{}
	snapshot := f.snapshot(key, false)
	if snapshot == "" {
		return 0
	}
	if err := json.Unmarshal([]byte(snapshot), &values); err != nil {
		f.t.Fatal(err)
	}
	v, ok := values[column].(float64)
	if !ok {
		f.t.Fatalf("missing count %s", column)
	}
	return int(v)
}
func (f *rollupFixture) requireCount(key, column string, want int) {
	f.t.Helper()
	if got := f.count(key, column); got != want {
		f.t.Fatalf("%s: %s=%d want%d", key, column, got, want)
	}
}
func (f *rollupFixture) requireOracle(key string, at time.Time) {
	f.t.Helper()
	selective := f.snapshot(key, false)
	if err := (PostgresSignalRollupStore{DB: f.db}).Refresh(context.Background(), at); err != nil {
		f.t.Fatal(err)
	}
	if oracle := f.snapshot(key, false); oracle != selective {
		f.t.Fatalf("incremental differs from oracle\n%s\n%s", selective, oracle)
	}
}

// Reject unsafe targets before opening a connection; query parameters must not
// override the host or database selected from the URL authority and path.
func validateRollupFixtureDSN(dsn string) error {
	unsafe := errors.New("rollup recovery tests require a loopback PostgreSQL URL and disposable database socialwire_go_test or tsw155_*")
	u, err := url.Parse(dsn)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") || u.Fragment != "" {
		return unsafe
	}
	switch u.Hostname() {
	case "127.0.0.1", "localhost", "::1":
	default:
		return unsafe
	}
	database := u.Path
	if !regexp.MustCompile(`^/(socialwire_go_test|tsw155_[a-z0-9_]+)$`).MatchString(database) {
		return unsafe
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return unsafe
	}
	for name, values := range query {
		if name != "sslmode" || len(values) != 1 {
			return unsafe
		}
		switch values[0] {
		case "disable", "allow", "prefer", "require", "verify-ca", "verify-full":
		default:
			return unsafe
		}
	}
	return nil
}
