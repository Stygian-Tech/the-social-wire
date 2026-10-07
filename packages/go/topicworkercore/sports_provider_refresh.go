package topicworkercore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type sportsResource struct {
	Key, Competition, Native string
	Interval                 time.Duration
}

var sportsPath = regexp.MustCompile(`^[a-z0-9/-]+$`)
var sportsAPIKey = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

func (w *Worker) sportsRows(ctx context.Context, path string) ([]map[string]string, error) {
	if !sportsPath.MatchString(path) {
		return nil, fmt.Errorf("invalid sports provider path")
	}
	return w.sportsURLRows(ctx, "https://www.thesportsdb.com/api/v2/json/"+path, true)
}
func (w *Worker) sportsURLRows(ctx context.Context, url string, authenticate bool) ([]map[string]string, error) {
	headers := map[string]string{}
	if authenticate {
		headers["X-API-KEY"] = w.env["THESPORTSDB_API_KEY"]
	}
	for attempt := 0; attempt < 3; attempt++ {
		data, status, err := w.HTTP.Request(ctx, "GET", url, nil, headers, 4000000, 12*time.Second)
		if err != nil {
			return nil, err
		}
		if status >= 500 && attempt < 2 {
			if err := pause(ctx, time.Duration((attempt+1)*2)*time.Second); err != nil {
				return nil, err
			}
			continue
		}
		if status != 200 {
			return nil, fmt.Errorf("sports provider HTTP status %d", status)
		}
		var root map[string]json.RawMessage
		if err := json.Unmarshal(data, &root); err != nil {
			return nil, err
		}
		keys := []string{}
		for key := range root {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		var rows []map[string]any
		found := false
		for _, key := range keys {
			if string(root[key]) == "null" {
				continue
			}
			decoder := json.NewDecoder(bytes.NewReader(root[key]))
			decoder.UseNumber()
			if err := decoder.Decode(&rows); err == nil {
				found = true
				break
			}
		}
		if !found {
			for _, key := range []string{"table", "schedule", "events", "list", "lookup"} {
				if raw, ok := root[key]; ok && string(raw) == "null" {
					found = true
					break
				}
			}
		}
		if !found || len(rows) > 3000 {
			return nil, fmt.Errorf("invalid sports provider rows")
		}
		result := []map[string]string{}
		for _, row := range rows {
			if row == nil {
				return nil, fmt.Errorf("invalid sports provider null row")
			}
			stringsRow := map[string]string{}
			for key, value := range row {
				switch v := value.(type) {
				case string:
					stringsRow[key] = v
				case json.Number:
					stringsRow[key] = v.String()
				case bool:
					if v {
						stringsRow[key] = "1"
					} else {
						stringsRow[key] = "0"
					}
				}
			}
			result = append(result, stringsRow)
		}
		return result, nil
	}
	return nil, fmt.Errorf("sports provider exhausted retries")
}
func (w *Worker) refreshSportsProviders(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	if w.env["SPORTS_PROVIDER_RIGHTS_CONFIRMED"] != "true" || w.env["THESPORTSDB_API_KEY"] == "" {
		return nil
	}
	catalog, err := w.sportsCatalog(ctx)
	if err != nil || catalog == nil {
		return err
	}
	mappings, seasons := map[string]string{}, map[string]string{}
	_ = json.Unmarshal([]byte(w.env["SPORTS_REVIEWED_COMPETITIONS"]), &mappings)
	_ = json.Unmarshal([]byte(w.env["SPORTS_REVIEWED_SEASONS"]), &seasons)
	for key, value := range mappings {
		if !sportscore.ValidProviderID(value) {
			delete(mappings, key)
		}
	}
	for key, value := range seasons {
		if !sportscore.ValidSeason(value) {
			delete(seasons, key)
		}
	}
	var tableCompetitions []string
	_ = json.Unmarshal([]byte(w.env["SPORTS_REVIEWED_STANDINGS"]), &tableCompetitions)
	eventsEnabled := w.env["SPORTS_EVENTS_ENABLED"] == "true"
	active := map[string]bool{}
	if eventsEnabled {
		rows, err := w.DB.QueryContext(ctx, `SELECT DISTINCT competition_id FROM sports_events WHERE expires_at>$1 AND(payload->>'status'='in-progress' OR (payload->>'startsAt')::timestamptz BETWEEN $2 AND $3)`, at, at.Add(-6*time.Hour), at.Add(time.Hour))
		if err != nil {
			return err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return err
			}
			active[id] = true
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
	}
	resources := []sportsResource{}
	for _, entity := range catalog.Entities {
		native, ok := mappings[entity.ID]
		if entity.Kind != "competition" || !ok {
			continue
		}
		resources = append(resources, sportsResource{"reference:" + entity.ID + ":v3", entity.ID, native, 24 * time.Hour})
		if eventsEnabled {
			interval := time.Hour
			if active[entity.ID] {
				interval = 5 * time.Minute
			}
			resources = append(resources, sportsResource{"events:" + entity.ID + ":v2", entity.ID, native, interval})
			if season, ok := seasons[entity.ID]; ok {
				resources = append(resources, sportsResource{"schedule:" + entity.ID + ":" + season, entity.ID, native, time.Hour})
				if contains(tableCompetitions, entity.ID) {
					resources = append(resources, sportsResource{"standings:" + entity.ID + ":" + season + ":v2", entity.ID, native, time.Hour})
				}
			}
		}
	}
	for _, entity := range catalog.Entities {
		if !contains([]string{"team", "ncaa-team"}, entity.Kind) {
			continue
		}
		native, ok := entity.ProviderIDs["thesportsdb"]
		if !ok {
			continue
		}
		for _, competition := range entity.CompetitionIDs {
			if _, ok := mappings[competition]; ok {
				resources = append(resources, sportsResource{"roster:" + entity.ID, competition, native, 24 * time.Hour})
				break
			}
		}
	}
	rows, err := w.DB.QueryContext(ctx, `SELECT resource_key,requested_at FROM sports_provider_refresh`)
	if err != nil {
		return err
	}
	requested := map[string]time.Time{}
	for rows.Next() {
		var key string
		var date time.Time
		if err := rows.Scan(&key, &date); err != nil {
			rows.Close()
			return err
		}
		requested[key] = date
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	due := []sportsResource{}
	for _, resource := range resources {
		date, ok := requested[resource.Key]
		if !ok || at.Sub(date) >= resource.Interval {
			due = append(due, resource)
		}
	}
	priority := func(resource sportsResource) int {
		if strings.HasPrefix(resource.Key, "events:") && resource.Interval == 5*time.Minute {
			return 0
		}
		if strings.HasPrefix(resource.Key, "roster:") {
			return 2
		}
		return 1
	}
	sort.SliceStable(due, func(i, j int) bool {
		a, b := due[i], due[j]
		if priority(a) != priority(b) {
			return priority(a) < priority(b)
		}
		return requested[a.Key].Before(requested[b.Key])
	})
	if len(due) == 0 {
		return nil
	}
	resource := due[0]
	tx, err := w.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fence(ctx, tx, authority); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO sports_provider_refresh(resource_key,requested_at)VALUES($1,$2)ON CONFLICT(resource_key)DO UPDATE SET requested_at=EXCLUDED.requested_at`, resource.Key, at); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if err := w.fetchSportsResource(ctx, authority, catalog, resource, seasons, at); err != nil {
		retry, beginErr := w.DB.BeginTx(ctx, nil)
		if beginErr != nil {
			return beginErr
		}
		defer retry.Rollback()
		if fenceErr := fence(ctx, retry, authority); fenceErr != nil {
			return fenceErr
		}
		if _, updateErr := retry.ExecContext(ctx, `UPDATE sports_provider_refresh SET requested_at=$1 WHERE resource_key=$2 AND requested_at=$3`, at.Add(-resource.Interval+5*time.Minute), resource.Key, at); updateErr != nil {
			return updateErr
		}
		if commitErr := retry.Commit(); commitErr != nil {
			return commitErr
		}
		return err
	}
	return nil
}
func (w *Worker) fetchSportsResource(ctx context.Context, authority *operationscore.RoleLeaseAuthority, catalog *sportsSnapshot, resource sportsResource, seasons map[string]string, at time.Time) error {
	if strings.HasPrefix(resource.Key, "standings:") {
		season := seasons[resource.Competition]
		if !sportscore.ValidSeason(season) || !sportscore.ValidProviderID(resource.Native) || !sportsAPIKey.MatchString(w.env["THESPORTSDB_API_KEY"]) {
			return fmt.Errorf("invalid reviewed sports standings mapping")
		}
		records, err := w.sportsURLRows(ctx, "https://www.thesportsdb.com/api/v1/json/"+w.env["THESPORTSDB_API_KEY"]+"/lookuptable.php?l="+resource.Native+"&s="+season, false)
		if err != nil {
			return err
		}
		rows := []sportscore.StandingRow{}
		source := "https://www.thesportsdb.com/table.php?l=" + resource.Native + "&s=" + season
		for _, record := range records {
			row := sportscore.ProviderStanding(record, resource.Competition, catalog.Entities, source)
			if row == nil {
				return fmt.Errorf("partially malformed standings response")
			}
			rows = append(rows, *row)
		}
		status := "available"
		if len(rows) == 0 {
			status = "empty"
		}
		table := sportscore.ReviewedStandingZones(sportscore.StandingSnapshot{CompetitionID: resource.Competition, Season: season, SourceURL: "https://www.thesportsdb.com/league/" + resource.Native, Status: status, UpdatedAt: at.UTC().Truncate(time.Second), Rows: rows})
		payload, err := json.Marshal(table)
		if err != nil {
			return err
		}
		tx, err := w.DB.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := fence(ctx, tx, authority); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)VALUES($1,$2,$3::jsonb,$4,$5)ON CONFLICT(competition_id,season)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, resource.Competition, season, string(payload), at, at.Add(72*time.Hour)); err != nil {
			return err
		}
		return tx.Commit()
	}
	if strings.HasPrefix(resource.Key, "events:") || strings.HasPrefix(resource.Key, "schedule:") {
		upcoming, err := w.sportsRows(ctx, "schedule/next/league/"+resource.Native)
		if err != nil {
			return err
		}
		path := "schedule/previous/league/" + resource.Native
		strict := false
		if strings.HasPrefix(resource.Key, "schedule:") {
			season := seasons[resource.Competition]
			if !sportscore.ValidSeason(season) || !sportscore.ValidProviderID(resource.Native) {
				return fmt.Errorf("invalid schedule mapping")
			}
			path = "schedule/league/" + resource.Native + "/" + season
			strict = true
		}
		recent, err := w.sportsRows(ctx, path)
		if err != nil {
			return err
		}
		events := []sportscore.Event{}
		for i, records := range [][]map[string]string{upcoming, recent} {
			for _, record := range records {
				event := sportscore.ProviderEvent(record, resource.Competition, catalog.Entities, at)
				if event == nil {
					if strict && i == 1 {
						return fmt.Errorf("partially malformed season schedule")
					}
					continue
				}
				events = append(events, *event)
			}
		}
		payload, err := json.Marshal(events)
		if err != nil {
			return err
		}
		status := "available"
		if len(events) == 0 {
			status = "empty"
		}
		schedulePayload, err := json.Marshal(map[string]any{"competitionID": resource.Competition, "status": status, "updatedAt": at.UTC().Truncate(time.Second)})
		if err != nil {
			return err
		}
		tx, err := w.DB.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		if err := fence(ctx, tx, authority); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)SELECT event->>'id',$1,event,$2,$3 FROM(SELECT DISTINCT ON(value->>'id')value AS event FROM jsonb_array_elements($4::jsonb))unique_events ON CONFLICT(event_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, resource.Competition, at, at.Add(48*time.Hour), string(payload)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at)VALUES($1,$2::jsonb,$3,$4)ON CONFLICT(competition_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, resource.Competition, string(schedulePayload), at, at.Add(72*time.Hour)); err != nil {
			return err
		}
		return tx.Commit()
	}
	return w.refreshSportsReference(ctx, authority, catalog, resource, at)
}
