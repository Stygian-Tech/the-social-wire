package topicreadcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"testing"
	"time"
)

func TestSportsPostgresScopedEventsBeforeLimitAndStandingsIdentity(t *testing.T) {
	db := selectionDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	ctx := context.Background()
	competition := "topic-events-competition"
	team := "topic-events-team"
	entities := []sportscore.Entity{{ID: competition, Name: "Fixture League", Kind: "competition", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}, {ID: team, Name: "Fixture Club", Kind: "team", CompetitionIDs: []string{competition}, Aliases: []string{"Fixture FC"}, ProviderIDs: map[string]string{"thesportsdb": "123"}, Abbreviation: ptr("FFC"), Memberships: []sportscore.Membership{}, Active: true}}
	for _, e := range entities {
		raw, _ := corpuscore.MarshalHTTP(e)
		if _, err := db.Exec(`INSERT INTO sports_entities(entity_id,payload,updated_at)VALUES($1,$2::jsonb,$3)`, e.ID, raw, now); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_events WHERE event_id LIKE 'topic-events-%'`)
		db.Exec(`DELETE FROM sports_standings WHERE competition_id=$1`, competition)
		db.Exec(`DELETE FROM sports_schedule_status WHERE competition_id=$1`, competition)
		db.Exec(`DELETE FROM sports_entities WHERE entity_id=ANY($1::text[])`, []string{team, competition})
	})
	s := &SportsStore{DB: db, Config: SportsConfig{Mode: "visible", EventsEnabled: true}}
	for _, event := range []sportscore.Event{{ID: "topic-events-matched", CompetitionID: competition, EntityIDs: []string{}, Title: "Fixture Club vs Visitors", StartsAt: now.Add(time.Hour), Status: "scheduled", HomeName: ptr("Fixture FC"), AwayName: ptr("Visitors"), UpdatedAt: now}, {ID: "topic-events-stale", CompetitionID: competition, EntityIDs: []string{team}, Title: "Old game", StartsAt: now.Add(-8 * 24 * time.Hour), Status: "finished", UpdatedAt: now}} {
		if err := s.importEvents(ctx, []sportscore.Event{event}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) SELECT 'topic-events-noise-'||n,'noise',jsonb_build_object('id','topic-events-noise-'||n,'competitionID','noise','entityIDs',jsonb_build_array('other'),'title','Noise','startsAt',$1::timestamptz,'status','in-progress','updatedAt',$1::timestamptz),$1,$1::timestamptz+interval '1 day' FROM generate_series(1,600)n`, now); err != nil {
		t.Fatal(err)
	}
	table := sportscore.StandingSnapshot{CompetitionID: competition, Season: "2026", SourceURL: "https://www.thesportsdb.com/", Status: "available", UpdatedAt: now, Rows: []sportscore.StandingRow{{ID: "row", Name: "Fixture FC", Rank: func() *int { v := 1; return &v }()}}}
	raw, _ := corpuscore.MarshalHTTP(table)
	if _, err := db.Exec(`INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)VALUES($1,'2026',$2::jsonb,$3,$4)`, competition, raw, now, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	result, err := s.Events(ctx, "sports", now, []string{team}, nil, time.UTC, "UTC")
	if err != nil || len(result.Events) != 1 || result.Events[0].ID != "topic-events-matched" || result.Events[0].HomeAbbreviation == nil || *result.Events[0].HomeAbbreviation != "FFC" || len(result.Standings) != 1 || result.Standings[0].Rows[0].EntityID == nil || *result.Standings[0].Rows[0].EntityID != team || result.Degraded || result.SchedulesStatus != "available" {
		t.Fatal(result, err)
	}
	empty, err := s.Events(ctx, "sports", now, []string{}, nil, time.UTC, "UTC")
	if err != nil || len(empty.Events) != 0 || empty.Degraded || empty.SchedulesStatus != "empty" {
		t.Fatal(empty, err)
	}
	if _, err = s.Events(ctx, "sports", now, []string{"invalid"}, nil, time.UTC, "UTC"); err != ErrInvalidCursor {
		t.Fatal(err)
	}
	definition := SportsDefinition{ID: "entity:" + competition, EntityIDs: []string{competition}}
	if _, err = db.Exec(`DELETE FROM sports_standings WHERE competition_id=$1`, competition); err != nil {
		t.Fatal(err)
	}
	missing, err := s.standings(ctx, definition, entities, now, nil, nil)
	if err != nil || len(missing) != 1 || missing[0].Status != "unavailable" {
		t.Fatal(missing, err)
	}
	payload, err := corpuscore.MarshalHTTP(missing)
	if err != nil {
		t.Fatal(err)
	}
	var decoded []map[string]any
	json.Unmarshal(payload, &decoded)
	if _, present := decoded[0]["updatedAt"]; present {
		t.Fatal("unobserved standing fabricated date", string(payload))
	}
}
func ptr(s string) *string { return &s }
func TestSportsEventOrderingViewerDayAndMembership(t *testing.T) {
	now := time.Date(2026, 10, 7, 2, 0, 0, 0, time.UTC)
	zone, _ := time.LoadLocation("America/Los_Angeles")
	catalog := []sportscore.Entity{{ID: "team", Kind: "team", Active: true}, {ID: "athlete", Kind: "athlete", Active: true, Memberships: []sportscore.Membership{{EntityID: "team", ValidFrom: now.Add(-time.Hour)}}}}
	events := []sportscore.Event{{ID: "future", StartsAt: now.Add(time.Hour), Status: "scheduled", EntityIDs: []string{}}, {ID: "preferred", StartsAt: now.Add(2 * time.Hour), Status: "scheduled", EntityIDs: []string{"team"}}, {ID: "result", StartsAt: now.Add(-2 * time.Hour), Status: "finished", EntityIDs: []string{}}, {ID: "live", StartsAt: now.Add(-24 * time.Hour), Status: "in-progress", EntityIDs: []string{}}}
	ordered := sportsOrder(events, now, []string{"athlete"}, catalog, zone)
	for i, id := range []string{"live", "result", "preferred", "future"} {
		if ordered[i].ID != id {
			t.Fatal(ordered)
		}
	}
}
