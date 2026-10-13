package topicreadcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type overlapCatalogConnector struct {
	now                        time.Time
	raw                        string
	started, release, finished chan struct{}
	once                       sync.Once
}

func (s *overlapCatalogConnector) Connect(context.Context) (driver.Conn, error) {
	return &overlapCatalogConn{s}, nil
}
func (*overlapCatalogConnector) Driver() driver.Driver { return reuseDriver{} }

type overlapCatalogConn struct{ state *overlapCatalogConnector }

func (*overlapCatalogConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (*overlapCatalogConn) Close() error { return nil }
func (*overlapCatalogConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected transaction")
}
func (c *overlapCatalogConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if strings.HasPrefix(query, "SELECT version,generated_at") {
		c.state.once.Do(func() { close(c.state.started) })
		select {
		case <-c.state.release:
		case <-ctx.Done():
			close(c.state.finished)
			return nil, ctx.Err()
		}
		return &reuseRows{columns: []string{"version", "generated"}, row: []driver.Value{"v1", c.state.now}}, nil
	}
	if strings.HasPrefix(query, "SELECT entities::text") {
		if len(args) > 0 && args[0].Value != "v1" {
			return &reuseRows{columns: []string{"payload"}}, nil
		}
		return &reuseRows{columns: []string{"payload"}, row: []driver.Value{c.state.raw}}, nil
	}
	return nil, errors.New("unexpected SQL")
}

type overlapRemote struct {
	corpuscore.Store
	call func(context.Context) (corpuscore.SportsSourceResponse, error)
}

func (s overlapRemote) SportsSource(ctx context.Context, _ corpuscore.SportsSourceRequest, _ time.Time) (corpuscore.SportsSourceResponse, error) {
	return s.call(ctx)
}

func overlapFixture(t *testing.T) (*SportsStore, *overlapCatalogConnector, corpuscore.SportsSourceResponse) {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	entities := []sportscore.Entity{{ID: "team", Name: "Team", Kind: "team", Active: true, CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}}}
	raw, _ := corpuscore.MarshalHTTP(entities)
	revision, _ := sportscore.ServingCatalogRevision(entities)
	state := &overlapCatalogConnector{now: now, raw: string(raw), started: make(chan struct{}), release: make(chan struct{}), finished: make(chan struct{})}
	db := sql.OpenDB(state)
	t.Cleanup(func() { db.Close() })
	candidates := []corpuscore.SportsSourceCandidate{}
	response := corpuscore.SportsSourceResponse{GenerationID: "aaaaaaaa-5555-5555-5555-555555555555", GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", CatalogVersion: "v1", CatalogGeneratedAt: now.Format(time.RFC3339Nano), CatalogRevision: revision, ServingCatalogRevision: revision, Candidates: &candidates}
	return &SportsStore{DB: db}, state, response
}

func TestLeanColdCatalogOverlapsAndPreservesIndependentObservers(t *testing.T) {
	store, state, response := overlapFixture(t)
	remoteStarted := make(chan struct{})
	counts := map[string]int{}
	observer := func(phase string, _ time.Duration) { counts[phase]++; time.Sleep(time.Microsecond) }
	ctx := corpuscore.WithQueryObserver(WithFeedPhaseObserver(context.Background(), observer), func(phase string, _ time.Duration) { counts["independent-"+phase]++; time.Sleep(time.Microsecond) })
	remote := overlapRemote{call: func(ctx context.Context) (corpuscore.SportsSourceResponse, error) {
		select {
		case <-state.started:
		case <-ctx.Done():
			return response, ctx.Err()
		}
		close(remoteStarted)
		for range 100 {
			corpuscore.QueryObserver(ctx)("query", 0)
		}
		return response, nil
	}}
	store.Remote = remote
	result := make(chan error, 1)
	go func() { _, err := store.source(ctx, "en", state.now); result <- err }()
	select {
	case <-remoteStarted:
	case <-time.After(time.Second):
		t.Fatal("source RPC did not overlap blocked local catalog")
	}
	close(state.release)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if counts["independent-query"] != 100 || counts["query"] != 0 || counts["catalog-cache-miss"] != 1 {
		t.Fatal("independent callbacks lost or redirected", counts)
	}
	// Existing validated catalog avoids speculative local work entirely.
	store.Remote = overlapRemote{call: func(context.Context) (corpuscore.SportsSourceResponse, error) { return response, nil }}
	if _, err := store.loadLeanSource(context.Background(), store.Remote.(corpuscore.SportsSourceStore), "en", state.now); err != nil {
		t.Fatal(err)
	}
}

func TestLeanColdCatalogDrainsOnRPCErrorAndCallerCancellation(t *testing.T) {
	for _, cancelCaller := range []bool{false, true} {
		store, state, response := overlapFixture(t)
		remoteStarted := make(chan struct{})
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		remote := overlapRemote{call: func(ctx context.Context) (corpuscore.SportsSourceResponse, error) {
			<-state.started
			close(remoteStarted)
			if cancelCaller {
				<-ctx.Done()
				return response, ctx.Err()
			}
			return response, ErrUnavailable
		}}
		store.Remote = remote
		result := make(chan error, 1)
		go func() { _, err := store.loadLeanSource(ctx, remote, "en", state.now); result <- err }()
		<-remoteStarted
		if cancelCaller {
			cancel()
		}
		select {
		case err := <-result:
			expected := error(ErrUnavailable)
			if cancelCaller {
				expected = context.Canceled
			}
			if !errors.Is(err, expected) {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("cold jobs did not drain")
		}
		select {
		case <-state.finished:
		default:
			t.Fatal("catalog goroutine escaped request lifetime")
		}
	}
}

func TestLeanColdOverlapStillRejectsRemoteCatalogMismatch(t *testing.T) {
	store, state, response := overlapFixture(t)
	close(state.release)
	response.CatalogVersion = "v2"
	store.Remote = overlapRemote{call: func(context.Context) (corpuscore.SportsSourceResponse, error) { return response, nil }}
	if _, err := store.source(context.Background(), "en", state.now); !errors.Is(err, ErrUnavailable) {
		t.Fatal("speculative local catalog bypassed remote lease proof", err)
	}
}

func TestPostgresSportsSourceImportGuardExistingAndAbsent(t *testing.T) {
	db := selectionDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	existing := "aaaaaaaa-6666-6666-6666-666666666666"
	absent := "bbbbbbbb-6666-6666-6666-666666666666"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id IN($1::uuid,$2::uuid)`, existing, absent)
	})
	if _, err := db.Exec(`INSERT INTO sports_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','guard',$2,$3,'[]'::jsonb,FALSE)`, existing, now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	store := &SportsStore{DB: db, Remote: leanPageCorpus{}, lastRetention: now}
	proposal := corpuscore.SportsGeneration{GenerationID: "cccccccc-6666-6666-6666-666666666666", GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", Candidates: []sportscore.RankCandidate{leanSnapshotCandidate("guard")}}
	source := proposal
	source.GenerationID = existing
	source.Candidates = []sportscore.RankCandidate{leanSnapshotCandidate("unused")}
	source.Candidates[0].BaseScore = math.NaN()
	var before string
	if err := db.QueryRow(`SELECT xmin::text FROM sports_generations WHERE generation_id=$1::uuid`, existing).Scan(&before); err != nil {
		t.Fatal(err)
	}
	if _, err := store.persist(context.Background(), proposal, source, "existing-scope", "revision", now); err != nil {
		t.Fatal("existing source was redundantly marshaled", err)
	}
	var after, payload string
	if err := db.QueryRow(`SELECT xmin::text,payload::text FROM sports_generations WHERE generation_id=$1::uuid`, existing).Scan(&after, &payload); err != nil || before != after || payload != "[]" {
		t.Fatal("canonical source changed", before, after, payload, err)
	}
	source.GenerationID = absent
	source.Candidates = proposal.Candidates
	proposal.GenerationID = "dddddddd-6666-6666-6666-666666666666"
	if _, err := store.persist(context.Background(), proposal, source, "absent-scope", "revision", now); err != nil {
		t.Fatal("missing source import failed", err)
	}
	if err := db.QueryRow(`SELECT payload::text FROM sports_generations WHERE generation_id=$1::uuid`, absent).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var imported []sportscore.RankCandidate
	if json.Unmarshal([]byte(payload), &imported) != nil || len(imported) != 1 || imported[0].Item.ItemID != "guard" {
		t.Fatal("missing source did not retain import behavior", payload)
	}
}
