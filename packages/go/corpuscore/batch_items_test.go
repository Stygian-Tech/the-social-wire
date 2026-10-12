package corpuscore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type batchSQLConnector struct {
	queries []string
	now     time.Time
	fresh   bool
	title   string
	omit    bool
}

func (c *batchSQLConnector) Connect(context.Context) (driver.Conn, error) {
	return &batchSQLConn{c}, nil
}
func (c *batchSQLConnector) Driver() driver.Driver { return batchSQLDriver{} }

type batchSQLDriver struct{}

func (batchSQLDriver) Open(string) (driver.Conn, error) { return nil, errors.New("use connector") }

type batchSQLConn struct{ state *batchSQLConnector }

func (c *batchSQLConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (c *batchSQLConn) Close() error                             { return nil }
func (c *batchSQLConn) Begin() (driver.Tx, error)                { return nil, errors.New("unexpected tx") }
func (c *batchSQLConn) CheckNamedValue(*driver.NamedValue) error { return nil }
func (c *batchSQLConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	c.state.queries = append(c.state.queries, query)
	if strings.Contains(query, "wire_serving.label_health") {
		return &batchSQLRows{columns: []string{"current", "oldest"}, values: [][]driver.Value{{c.state.fresh, c.state.now}}}, nil
	}
	if !strings.Contains(query, "FROM wire_serving.items WHERE canonical_key=ANY($1::text[])") || len(args) != 1 {
		return nil, fmt.Errorf("unexpected query: %s", query)
	}
	ids, ok := args[0].Value.([]string)
	if !ok || len(ids) != 100 {
		return nil, errors.New("expected one 100-ID argument")
	}
	columns := make([]string, 16)
	for i := range columns {
		columns[i] = fmt.Sprint(i)
	}
	rows := &batchSQLRows{columns: columns}
	if !c.state.omit {
		rows.values = [][]driver.Value{{ids[99], "https://example.com", nil, c.state.title, nil, nil, nil, "Example", "example.com", nil, nil, "[]", "did:example:source", nil, nil, nil}}
	}
	return rows, nil
}

type batchSQLRows struct {
	columns []string
	values  [][]driver.Value
}

func (r *batchSQLRows) Columns() []string { return r.columns }
func (r *batchSQLRows) Close() error      { return nil }
func (r *batchSQLRows) Next(dest []driver.Value) error {
	if len(r.values) == 0 {
		return io.EOF
	}
	copy(dest, r.values[0])
	r.values = r.values[1:]
	return nil
}
func TestPostgresBatchQueryBudgetAndCurrentPayload(t *testing.T) {
	now := time.Now()
	state := &batchSQLConnector{now: now, fresh: true, title: "Before"}
	db := sql.OpenDB(state)
	defer db.Close()
	store := &PostgreSQLStore{DB: db, Cache: &PayloadCache{}}
	ids := make([]string, 100)
	for i := range ids {
		ids[i] = fmt.Sprintf("item-%d", i)
	}
	for _, title := range []string{"Before", "After"} {
		state.title = title
		state.queries = nil
		items, err := store.Items(context.Background(), ids, now)
		if err != nil || len(items) != 1 || items[0].Item.Title != title || items[0].Item.ItemID != "item-99" || len(state.queries) != 2 {
			t.Fatal(items, err, state.queries)
		}
	}
	phaseCounts := map[string]int{}
	observed := WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phaseCounts[phase]++ })
	state.queries = nil
	if _, err := store.Items(observed, ids, now); err != nil || len(state.queries) != 2 || phaseCounts["db-acquisition"] != 2 || phaseCounts["db-query"] != 2 || db.Stats().InUse != 0 {
		t.Fatal("observed batch query budget", err, state.queries, phaseCounts, db.Stats())
	}
	state.omit = true
	items, err := store.Items(context.Background(), ids, now)
	if err != nil || len(items) != 0 {
		t.Fatal(items, err)
	}
	state.fresh = false
	state.queries = nil
	if _, err = store.Items(context.Background(), ids, now); !errors.Is(err, ErrModerationUnavailable) || len(state.queries) != 1 {
		t.Fatal(err, state.queries)
	}
}

type batchRoundTripper func(*http.Request) (*http.Response, error)

func (f batchRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestRemoteBatchSigningAndResponseMembership(t *testing.T) {
	now := time.Now()
	secret := strings.Repeat("s", 32)
	response := `{"items":{}}`
	calls := 0
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", secret}, &http.Client{Transport: batchRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls++
		body, _ := io.ReadAll(r.Body)
		digest := r.Header.Get(wirecore.CorpusBodyDigestHeader)
		headers := wirecore.CorpusServiceHeaders{ServiceID: r.Header.Get(wirecore.CorpusServiceHeader), Timestamp: r.Header.Get(wirecore.CorpusTimestampHeader), Nonce: r.Header.Get(wirecore.CorpusNonceHeader), Signature: r.Header.Get(wirecore.CorpusSignatureHeader), BodyDigest: &digest}
		if r.Method != "POST" || r.URL.Path != BatchItemsPath || digest != wirecore.CorpusBodyDigest(body) || wirecore.VerifyCorpusRequest([]byte(secret), "appview", r.Method, r.URL.RequestURI(), headers, now) != nil {
			t.Fatal("invalid signed batch")
		}
		if r.Header.Get("Authorization") != "" || r.Header.Get("DPoP") != "" {
			t.Fatal("viewer credentials leaked")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": []string{"3"}}, Body: io.NopCloser(strings.NewReader(response))}, nil
	})})
	remote.Now = func() time.Time { return now }
	if items, err := remote.Items(context.Background(), []string{"a", "b"}, now); err != nil || len(items) != 0 {
		t.Fatal(items, err)
	}
	item := func(id string) Item {
		return Item{Item: wirecore.FeedItem{ItemID: id, CanonicalURL: "https://example.com", Title: "Current", Source: wirecore.ItemSource{Name: "Example", Domain: "example.com"}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}}
	}
	valid, _ := MarshalHTTP(ItemsResponse{Items: map[string]Item{"b": item("b"), "a": item("a")}})
	response = string(valid)
	if items, err := remote.Items(context.Background(), []string{"a", "b"}, now); err != nil || len(items) != 2 {
		t.Fatal(items, err)
	}
	for _, items := range []map[string]Item{{"wrong": item("wrong")}, {"b": item("a")}} {
		body, _ := MarshalHTTP(ItemsResponse{Items: items})
		response = string(body)
		if _, err := remote.Items(context.Background(), []string{"a", "b"}, now); !errors.Is(err, ErrContractMismatch) {
			t.Fatal(response, err)
		}
	}
	response = `{"items":null}`
	if _, err := remote.Items(context.Background(), []string{"a", "b"}, now); !errors.Is(err, ErrContractMismatch) {
		t.Fatal(response, err)
	}

	if _, err := remote.Items(context.Background(), []string{"a", "a"}, now); !errors.Is(err, ErrContractMismatch) || calls != 5 {
		t.Fatal(err, calls)
	}
}
