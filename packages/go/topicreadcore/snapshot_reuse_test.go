package topicreadcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"io"
	"strings"
	"testing"
	"time"
)

type reuseConnector struct {
	beforeQuery func(string)
	stamp       string
	queries     int
	query       string
	args        []driver.NamedValue
	row         []driver.Value
	err         error
}

func (s *reuseConnector) Connect(context.Context) (driver.Conn, error) { return &reuseConn{s}, nil }
func (s *reuseConnector) Driver() driver.Driver                        { return reuseDriver{} }

type reuseDriver struct{}

func (reuseDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type reuseConn struct{ state *reuseConnector }

func (c *reuseConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (c *reuseConn) Close() error              { return nil }
func (c *reuseConn) Begin() (driver.Tx, error) { return nil, errors.New("unexpected transaction") }
func (c *reuseConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if c.state.beforeQuery != nil {
		c.state.beforeQuery(query)
	}
	c.state.queries++
	if !strings.HasPrefix(query, "SELECT payload::text") {
		c.state.query = query
		c.state.args = args
	}
	if c.state.err != nil {
		return nil, c.state.err
	}
	if strings.HasPrefix(query, "SELECT payload::text") {
		if c.state.row == nil {
			return &reuseRows{columns: []string{"payload"}}, nil
		}
		return &reuseRows{columns: []string{"payload"}, row: []driver.Value{c.state.row[3]}}, nil
	}
	stamp := c.state.stamp
	if stamp == "" {
		stamp = "1:(0,1)"
	}
	if c.state.row == nil {
		return &reuseRows{columns: []string{"snapshot", "generated", "expires", "source", "stamp"}}, nil
	}
	return &reuseRows{columns: []string{"snapshot", "generated", "expires", "source", "stamp"}, row: []driver.Value{c.state.row[0], c.state.row[1], c.state.row[2], c.state.row[4], stamp}}, nil
}

type reuseRows struct {
	row     []driver.Value
	columns []string
}

func (r *reuseRows) Columns() []string {
	return r.columns
}
func (r *reuseRows) Close() error { return nil }
func (r *reuseRows) Next(out []driver.Value) error {
	if r.row == nil {
		return io.EOF
	}
	copy(out, r.row)
	r.row = nil
	return nil
}

func TestPersonalizedSnapshotLookupFencesAndFailure(t *testing.T) {
	now := time.Now()
	generation := "77777777-1111-1111-1111-111111111111"
	snapshot := "88888888-1111-1111-1111-111111111111"
	for _, domain := range []string{"finance", "sports"} {
		t.Run(domain, func(t *testing.T) {
			state := &reuseConnector{row: []driver.Value{snapshot, now, now.Add(time.Hour), "[]", "ranked"}}
			db := sql.OpenDB(state)
			defer db.Close()
			lookup := func(ctx context.Context) (bool, error) {
				if domain == "finance" {
					value, err := (&FinanceStore{DB: db}).reusable(ctx, generation, "viewer:feed", "en", "preferences:resolver:catalog", now)
					return value != nil, err
				}
				value, err := (&SportsStore{DB: db}).reusable(ctx, generation, "viewer:feed", "en", "preferences:resolver:catalog", now)
				return value != nil, err
			}
			if found, err := lookup(context.Background()); err != nil || !found || state.queries != 2 {
				t.Fatal(found, err, state.queries)
			}
			for _, fence := range []string{"FROM " + domain + "_personalized_snapshots", "source_generation_id=$1::uuid", "viewer_scope=$2", "language=$3", "preference_revision=$4", "expires_at>$5"} {
				if !strings.Contains(state.query, fence) {
					t.Fatal("missing lookup fence", fence, state.query)
				}
			}
			if len(state.args) != 5 || state.args[0].Value != generation || state.args[1].Value != "viewer:feed" || state.args[2].Value != "en" || state.args[3].Value != "preferences:resolver:catalog" || state.args[4].Value != now {
				t.Fatal(state.args)
			}
			state.row = nil
			if found, err := lookup(context.Background()); found || err != nil {
				t.Fatal("missing row", found, err)
			}
			state.err = errors.New("database unavailable")
			if found, err := lookup(context.Background()); found || err == nil {
				t.Fatal("query error", found, err)
			}
			count := state.queries
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if found, err := lookup(ctx); found || !errors.Is(err, context.Canceled) || state.queries != count {
				t.Fatal("cancelled lookup", found, err, state.queries)
			}
			state.err = nil
			state.row = []driver.Value{snapshot, now, now.Add(time.Hour), "{}", "ranked"}
			if found, err := lookup(context.Background()); found || !errors.Is(err, corpuscore.ErrContractMismatch) {
				t.Fatal("malformed snapshot", found, err)
			}
		})
	}
}
func TestSportsSnapshotReuseRejectsObsoleteResolver(t *testing.T) {
	now := time.Now()
	payload, err := corpuscore.MarshalHTTP([]sportscore.RankCandidate{{Item: topicItem("a"), Analysis: sportscore.ArticleAnalysis{ResolverVersion: "obsolete", Eligible: true, Materiality: "championship", Associations: []sportscore.Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}, BaseScore: 1}})
	if err != nil {
		t.Fatal(err)
	}
	state := &reuseConnector{row: []driver.Value{"88888888-1111-1111-1111-111111111111", now, now.Add(time.Hour), string(payload), "ranked"}}
	db := sql.OpenDB(state)
	defer db.Close()
	value, err := (&SportsStore{DB: db}).reusable(context.Background(), "77777777-1111-1111-1111-111111111111", "viewer:feed", "en", "revision", now)
	if value != nil || err != nil || state.queries != 2 {
		t.Fatal(value, err, state.queries)
	}
}
