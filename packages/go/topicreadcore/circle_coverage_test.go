package topicreadcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type circleCoverageConnector struct {
	recovering, fail bool
	queries          int
}

func (c *circleCoverageConnector) Connect(context.Context) (driver.Conn, error) {
	return &circleCoverageConnection{c}, nil
}
func (c *circleCoverageConnector) Driver() driver.Driver { return circleCoverageDriver{} }

type circleCoverageDriver struct{}

func (circleCoverageDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("use connector")
}

type circleCoverageConnection struct{ state *circleCoverageConnector }

func (*circleCoverageConnection) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (*circleCoverageConnection) Close() error { return nil }
func (*circleCoverageConnection) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected transaction")
}
func (c *circleCoverageConnection) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	if strings.Contains(query, "wire_publication_recovery_health") {
		c.state.queries++
		if c.state.fail {
			return nil, errors.New("coverage unavailable")
		}
		return &circleCoverageRows{values: [][]driver.Value{{c.state.recovering}}}, nil
	}
	if strings.Contains(query, "appview_circle_hidden_items") {
		return &circleCoverageRows{}, nil
	}
	return nil, errors.New("unexpected query")
}

type circleCoverageRows struct{ values [][]driver.Value }

func (*circleCoverageRows) Columns() []string { return []string{"value"} }
func (*circleCoverageRows) Close() error      { return nil }
func (r *circleCoverageRows) Next(dest []driver.Value) error {
	if len(r.values) == 0 {
		return io.EOF
	}
	copy(dest, r.values[0])
	r.values = r.values[1:]
	return nil
}

type circleCoverageProfiles struct{ calls int }

func (p *circleCoverageProfiles) Profiles(context.Context, []string) (map[string]CircleIdentity, error) {
	p.calls++
	return map[string]CircleIdentity{}, nil
}

func TestCircleEditionRechecksCoverageOnCacheHitsAndClearsAfterRepair(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	connector := &circleCoverageConnector{recovering: true}
	db := sql.OpenDB(connector)
	defer db.Close()
	hasher, _ := wirecore.NewActorHasher([]byte(strings.Repeat("s", 32)))
	cursor, _ := wirecore.NewCircleCursorCodec([]byte(strings.Repeat("c", 32)))
	viewer := "did:example:coverage-viewer"
	state := &CirclePrivateState{DB: db, Hasher: hasher, Cache: circleCacheFixture(t)}
	complete := true
	graph := CircleGraph{SnapshotID: "11111111-1111-1111-1111-111111111111", ViewerDID: viewer, GeneratedAt: now, DirectMembers: []CircleMember{}, OneHopMembers: []CircleMember{}, OneHopExpansionComplete: &complete}
	if err := state.StoreGraph(ctx, graph, map[string]bool{viewer: true}, now); err != nil {
		t.Fatal(err)
	}
	moderation := NewModerationService(nil, nil)
	moderation.Cache.Store(viewer, ModerationSnapshot{FetchedAt: now})
	profiles := &circleCoverageProfiles{}
	service := CircleService{Corpus: circleCorpusFixture{page: corpuscore.CandidateResponse{GenerationID: "fixture", GeneratedAt: now, Language: "en", Stories: []corpuscore.CandidateStory{}}}, State: state, Hasher: hasher, Cursor: cursor, Moderation: moderation, Profiles: profiles}
	auth := gatewaycore.AuthContext{DID: viewer}
	for index, fixture := range []struct{ recovering, fail, want bool }{
		{true, false, true},
		{false, false, false},
		{true, false, true},
		{false, true, true},
		{false, false, false},
	} {
		connector.recovering, connector.fail = fixture.recovering, fixture.fail
		edition, err := service.Edition(ctx, auth, "", "en", "", now)
		if err != nil || edition.Degraded != fixture.want {
			t.Fatalf("coverage transition %d: degraded=%t want=%t err=%v", index, edition.Degraded, fixture.want, err)
		}
	}
	if connector.queries != 5 || profiles.calls != 1 {
		t.Fatalf("cache hits skipped current coverage or rebuilt presentation: coverage=%d builds=%d", connector.queries, profiles.calls)
	}
	complete = false
	graph.OneHopExpansionComplete = &complete
	if err := state.StoreGraph(ctx, graph, map[string]bool{viewer: true}, now); err != nil {
		t.Fatal(err)
	}
	edition, err := service.Edition(ctx, auth, "", "en", "", now)
	if err != nil || !edition.Degraded {
		t.Fatal("repair incorrectly cleared independent graph degradation", edition, err)
	}
}
