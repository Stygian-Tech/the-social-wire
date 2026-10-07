package topicworkercore

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type fixtureTransport struct {
	calls   []string
	respond func(string) ([]byte, int, error)
}

func (f *fixtureTransport) Request(_ context.Context, _ string, url string, _ []byte, _ map[string]string, _ int64, _ time.Duration) ([]byte, int, error) {
	f.calls = append(f.calls, url)
	return f.respond(url)
}
func TestSportsRefreshReferenceRosterAndFailureRetention(t *testing.T) {
	db := topicDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	competition := sportscore.ReviewedID("competition:premier-league")
	sport := sportscore.ReviewedID("sport:football")
	env := map[string]string{"SPORTS_FEED_MODE": "visible", "SPORTS_PROVIDER_RIGHTS_CONFIRMED": "true", "THESPORTSDB_API_KEY": "fixture-key", "SPORTS_REVIEWED_COMPETITIONS": `{"` + competition + `":"4328"}`}
	worker, _ := NewWorker(db, env)
	store := operationscore.PostgresRoleLeaseStore{DB: db, Environment: "dev"}
	lease, err := store.Acquire(ctx, "indexing.wire-materializer", "topic-provider-test", 30*time.Second)
	if err != nil || lease == nil {
		t.Fatal(err)
	}
	defer store.Release(ctx, lease.RoleLeaseAuthority)
	exec(t, db, `DELETE FROM sports_provider_refresh`)
	entities := []sportscore.Entity{{ID: competition, Name: "Premier League", Kind: "competition", SportID: &sport, CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}}
	if err := worker.publishSportsCatalog(ctx, &lease.RoleLeaseAuthority, entities, now); err != nil {
		t.Fatal(err)
	}
	transport := &fixtureTransport{respond: func(url string) ([]byte, int, error) {
		if strings.Contains(url, "list/teams/") {
			return []byte(`{"list":[{"idTeam":"123","strTeam":"Liverpool","strTeamShort":"LIV"}]}`), 200, nil
		}
		if strings.Contains(url, "list/players/") {
			return []byte(`{"list":[{"idPlayer":"99","strPlayer":"John Player"}]}`), 200, nil
		}
		return nil, 0, fmt.Errorf("unexpected fixture request")
	}}
	worker.HTTP = transport
	if err := worker.RefreshProviders(ctx, &lease.RoleLeaseAuthority, now); err != nil {
		t.Fatal(err)
	}
	snapshot, err := worker.sportsCatalog(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var team *sportscore.Entity
	for _, entity := range snapshot.Entities {
		if entity.ProviderIDs["thesportsdb"] == "123" {
			v := entity
			team = &v
		}
	}
	if team == nil || team.Abbreviation == nil || *team.Abbreviation != "LIV" {
		t.Fatal("reference identity/abbreviation not imported")
	}
	if err := worker.RefreshProviders(ctx, &lease.RoleLeaseAuthority, now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	snapshot, _ = worker.sportsCatalog(ctx)
	var player *sportscore.Entity
	for _, entity := range snapshot.Entities {
		if entity.ProviderIDs["thesportsdb"] == "99" {
			v := entity
			player = &v
		}
	}
	if player == nil || len(player.Memberships) != 1 || player.Memberships[0].EntityID != team.ID {
		t.Fatal("roster identity/membership missing")
	}
	stableID := player.ID
	exec(t, db, `UPDATE sports_provider_refresh SET requested_at=$1 WHERE resource_key=$2`, now.Add(-25*time.Hour), "roster:"+team.ID)
	if err := worker.RefreshProviders(ctx, &lease.RoleLeaseAuthority, now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	snapshot, _ = worker.sportsCatalog(ctx)
	for _, entity := range snapshot.Entities {
		if entity.ProviderIDs["thesportsdb"] == "99" && entity.ID != stableID {
			t.Fatal("repeat roster import changed identity")
		}
	}
	before := snapshot.Version
	transport.respond = func(string) ([]byte, int, error) { return []byte(`{}`), 400, nil }
	exec(t, db, `UPDATE sports_provider_refresh SET requested_at=$1 WHERE resource_key=$2`, now.Add(-25*time.Hour), "reference:"+competition+":v3")
	if err := worker.RefreshProviders(ctx, &lease.RoleLeaseAuthority, now.Add(3*time.Second)); err == nil {
		t.Fatal("failed provider silently succeeded")
	}
	snapshot, _ = worker.sportsCatalog(ctx)
	if snapshot.Version != before {
		t.Fatal("failure replaced last-successful catalog")
	}
	var claimed time.Time
	if err := db.QueryRow(`SELECT requested_at FROM sports_provider_refresh WHERE resource_key=$1`, "reference:"+competition+":v3").Scan(&claimed); err != nil {
		t.Fatal(err)
	}
	if !claimed.Equal(now.Add(3*time.Second - 24*time.Hour + 5*time.Minute)) {
		t.Fatal("failure retry claim did not preserve 5-minute retry budget")
	}
	blocked, _ := NewWorker(db, map[string]string{"SPORTS_FEED_MODE": "visible", "THESPORTSDB_API_KEY": "fixture-key"})
	blocked.HTTP = transport
	calls := len(transport.calls)
	if err := blocked.RefreshProviders(ctx, &lease.RoleLeaseAuthority, now); err != nil || len(transport.calls) != calls {
		t.Fatal("provider work ran without confirmed rights")
	}
}
func TestProviderRowsAndFinanceRetry(t *testing.T) {
	db := topicDB(t)
	worker, _ := NewWorker(db, map[string]string{"OPENFIGI_API_KEY": "fixture-key"})
	transport := &fixtureTransport{respond: func(string) ([]byte, int, error) {
		return []byte(`[{"data":[{"figi":"BBG000B9Y5X2","name":"APPLE INC","ticker":"AAPL","securityType2":"Common Stock","exchCode":"US"}]}]`), 200, nil
	}}
	worker.HTTP = transport
	rows, err := worker.mapFIGIs(context.Background(), []string{"BBG000B9Y5X2"})
	if err != nil || len(rows) != 1 || rows[0].Aliases == nil || !rows[0].IsActive {
		t.Fatalf("mapped rows %+v err=%v", rows, err)
	}
	transport.respond = func(string) ([]byte, int, error) {
		return []byte(`{"list":[{"idTeam":9007199254740993,"strTeam":"Liverpool","active":true}]}`), 200, nil
	}
	records, err := worker.sportsRows(context.Background(), "list/teams/4328")
	if err != nil || records[0]["idTeam"] != "9007199254740993" || records[0]["active"] != "1" {
		t.Fatalf("numeric provider decoding %v %v", records, err)
	}
	transport.respond = func(string) ([]byte, int, error) { return []byte(`{"schedule":null}`), 200, nil }
	records, err = worker.sportsRows(context.Background(), "schedule/next/league/4328")
	if err != nil || len(records) != 0 {
		t.Fatal("successful empty schedule rejected")
	}
	transport.respond = func(string) ([]byte, int, error) { return []byte(`{"list":[null]}`), 200, nil }
	if _, err := worker.sportsRows(context.Background(), "list/teams/4328"); err == nil {
		t.Fatal("null provider row accepted")
	}
	data, _ := json.Marshal(records)
	if string(data) != "[]" {
		t.Fatal("empty results encoded as null")
	}
}
