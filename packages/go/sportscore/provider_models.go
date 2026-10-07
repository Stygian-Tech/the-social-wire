package sportscore

import (
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Event struct {
	ID             string    `json:"id"`
	CompetitionID  string    `json:"competitionID"`
	EntityIDs      []string  `json:"entityIDs"`
	Title          string    `json:"title"`
	StartsAt       time.Time `json:"startsAt"`
	StartTimeKnown bool      `json:"startTimeKnown"`
	Status         string    `json:"status"`
	HomeName       *string   `json:"homeName,omitempty"`
	AwayName       *string   `json:"awayName,omitempty"`
	HomeScore      *string   `json:"homeScore,omitempty"`
	AwayScore      *string   `json:"awayScore,omitempty"`
	UpdatedAt      time.Time `json:"updatedAt"`
}
type StandingZone struct {
	Kind      string `json:"kind"`
	Label     string `json:"label"`
	SourceURL string `json:"sourceURL"`
}
type StandingRow struct {
	ID       string        `json:"id"`
	EntityID *string       `json:"entityID,omitempty"`
	Name     string        `json:"name"`
	Rank     *int          `json:"rank,omitempty"`
	Played   *int          `json:"played,omitempty"`
	Won      *int          `json:"won,omitempty"`
	Drawn    *int          `json:"drawn,omitempty"`
	Lost     *int          `json:"lost,omitempty"`
	Points   *string       `json:"points,omitempty"`
	Group    *string       `json:"group,omitempty"`
	Zone     *StandingZone `json:"zone,omitempty"`
}
type StandingSnapshot struct {
	CompetitionID string        `json:"competitionID"`
	Season        string        `json:"season"`
	SourceURL     string        `json:"sourceURL"`
	Status        string        `json:"status"`
	UpdatedAt     time.Time     `json:"updatedAt"`
	Degraded      bool          `json:"degraded"`
	Rows          []StandingRow `json:"rows"`
}

var numericID = regexp.MustCompile(`^[0-9]+$`)
var seasonFormat = regexp.MustCompile(`^[0-9]{4}(-[0-9]{4})?$`)
var eventClock = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$`)
var naiveTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$`)

func ValidProviderID(value string) bool { return numericID.MatchString(value) }
func ValidSeason(value string) bool     { return seasonFormat.MatchString(value) }
func ProviderStatus(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch {
	case strings.Contains(value, "cancel") || value == "canc":
		return "cancelled"
	case strings.Contains(value, "postpon") || in([]string{"pst", "post"}, value):
		return "postponed"
	case in([]string{"match finished", "ft", "aet", "aot", "ap", "pen", "finished"}, value):
		return "finished"
	case in([]string{"1h", "2h", "ht", "live", "in progress", "q1", "q2", "q3", "q4", "p1", "p2", "p3", "ot", "et", "p", "pt", "bt", "s1", "s2", "s3", "s4", "s5", "in1", "in2", "in3", "in4", "in5", "in6", "in7", "in8", "in9"}, value):
		return "in-progress"
	}
	return "scheduled"
}
func ProviderTimestamp(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if naiveTimestamp.MatchString(value) {
		value += "Z"
	}
	return time.Parse(time.RFC3339Nano, value)
}
func optional(row map[string]string, key string) *string {
	value, ok := row[key]
	if !ok {
		return nil
	}
	return &value
}
func ProviderEvent(row map[string]string, competition string, entities []Entity, now time.Time) *Event {
	if row["idEvent"] == "" || row["strEvent"] == "" {
		return nil
	}
	date, err := ProviderTimestamp(row["strTimestamp"])
	known := err == nil
	if err != nil {
		clock := strings.TrimSpace(row["strTime"])
		if eventClock.MatchString(clock) {
			if len(clock) == 5 {
				clock += ":00"
			}
			date, err = ProviderTimestamp(row["dateEvent"] + "T" + clock + "Z")
			known = err == nil
		}
		if err != nil {
			date, err = ProviderTimestamp(row["dateEvent"] + "T00:00:00Z")
		}
	}
	if err != nil {
		return nil
	}
	status := ProviderStatus(row["strStatus"])
	ids := []string{}
	for _, entity := range entities {
		if in([]string{"team", "ncaa-team"}, entity.Kind) && in(entity.CompetitionIDs, competition) {
			native, ok := entity.ProviderIDs["thesportsdb"]
			if ok && (native == row["idHomeTeam"] || native == row["idAwayTeam"]) {
				ids = append(ids, entity.ID)
			}
		}
	}
	event := &Event{ID: "tsdb:" + row["idEvent"], CompetitionID: competition, EntityIDs: ids, Title: row["strEvent"], StartsAt: date.UTC().Truncate(time.Second), StartTimeKnown: known, Status: status, HomeName: optional(row, "strHomeTeam"), AwayName: optional(row, "strAwayTeam"), UpdatedAt: now.UTC().Truncate(time.Second)}
	if status == "finished" || status == "in-progress" {
		event.HomeScore = optional(row, "intHomeScore")
		event.AwayScore = optional(row, "intAwayScore")
	}
	return event
}
func ProviderStanding(row map[string]string, competition string, entities []Entity, source string) *StandingRow {
	native := row["idTeam"]
	name := row["strTeam"]
	if !ValidProviderID(native) || strings.TrimSpace(name) == "" {
		return nil
	}
	ids := []string{}
	for _, entity := range entities {
		if in([]string{"team", "ncaa-team"}, entity.Kind) && in(entity.CompetitionIDs, competition) && entity.ProviderIDs["thesportsdb"] == native {
			ids = append(ids, entity.ID)
		}
	}
	var entityID *string
	if len(ids) == 1 {
		entityID = &ids[0]
	}
	stat := func(key string) *int {
		n, err := strconv.Atoi(row[key])
		if err != nil || n < 0 {
			return nil
		}
		return &n
	}
	value := &StandingRow{ID: "tsdb:" + native, EntityID: entityID, Name: name, Rank: stat("intRank"), Played: stat("intPlayed"), Won: stat("intWin"), Drawn: stat("intDraw"), Lost: stat("intLoss"), Points: optional(row, "intPoints"), Group: optional(row, "strGroup")}
	label := strings.TrimSpace(row["strDescription"])
	normalized := strings.ToLower(label)
	kind := ""
	switch {
	case strings.Contains(normalized, "relegation"):
		kind = "relegation"
	case strings.Contains(normalized, "play off") || strings.Contains(normalized, "play-off") || strings.Contains(normalized, "playoff"):
		kind = "playoff"
	case strings.Contains(normalized, "champions league") || strings.Contains(normalized, "europa league") || strings.Contains(normalized, "conference league") || strings.Contains(normalized, "copa libertadores") || strings.Contains(normalized, "copa sudamericana") || strings.Contains(normalized, "qualif"):
		kind = "qualification"
	case strings.Contains(normalized, "promotion"):
		kind = "promotion"
	}
	if kind != "" && len([]rune(label)) <= 512 {
		value.Zone = &StandingZone{kind, label, source}
	}
	return value
}
func ReviewedStandingZones(table StandingSnapshot) StandingSnapshot {
	if table.Season != "2026-2027" {
		return table
	}
	premier := table.CompetitionID == ReviewedID("competition:premier-league")
	championship := table.CompetitionID == ReviewedID("competition:efl-championship")
	expected := 0
	if premier {
		expected = 20
	}
	if championship {
		expected = 24
	}
	if expected == 0 || len(table.Rows) != expected {
		return table
	}
	ranks := map[int]bool{}
	for _, row := range table.Rows {
		if (row.Group != nil && *row.Group != "") || row.Rank == nil {
			return table
		}
		ranks[*row.Rank] = true
	}
	for rank := 1; rank <= expected; rank++ {
		if !ranks[rank] {
			return table
		}
	}
	for i, row := range table.Rows {
		if row.Zone != nil {
			continue
		}
		rank := *row.Rank
		source := "https://www.premierleague.com/en/news/4365156"
		switch {
		case premier && rank >= 18:
			table.Rows[i].Zone = &StandingZone{"relegation", "Relegation Places", source}
		case championship && rank <= 2:
			table.Rows[i].Zone = &StandingZone{"promotion", "Automatic Promotion Places", source}
		case championship && rank >= 3 && rank <= 8:
			table.Rows[i].Zone = &StandingZone{"playoff", "Promotion Play-Off Places", "https://www.efl.com/news/2026/march/05/efl-statement--sky-bet-championship-play-off-format/"}
		}
	}
	return table
}
func ProviderAbbreviation(value, native string) *string {
	code := strings.ToUpper(strings.TrimSpace(value))
	if !ValidProviderID(native) || len(code) < 2 || len(code) > 8 {
		return nil
	}
	for _, r := range code {
		if !((r >= '0' && r <= '9') || (r >= 'A' && r <= 'Z')) {
			return nil
		}
	}
	return &code
}
func ImportTeam(record map[string]string, competition Entity, existing []Entity, now time.Time, newID func() string) *Entity {
	native, ok := record["idTeam"]
	name := record["strTeam"]
	if !ok || name == "" {
		return nil
	}
	supplied := gender(Normalize(record["strGender"]))
	if supplied != "" && competition.Gender != nil && supplied != *competition.Gender {
		return nil
	}
	expected := competition.Gender
	if supplied != "" {
		expected = &supplied
	}
	var previous *Entity
	for _, entity := range existing {
		if in([]string{"team", "ncaa-team", "national-side"}, entity.Kind) && equalPtr(entity.SportID, competition.SportID) && entity.ProviderIDs["thesportsdb"] == native {
			value := entity
			previous = &value
			break
		}
	}
	if previous == nil {
		for _, entity := range existing {
			if in([]string{"team", "ncaa-team", "national-side"}, entity.Kind) && equalPtr(entity.SportID, competition.SportID) && in(entity.CompetitionIDs, competition.ID) && entity.Name == name {
				value := entity
				previous = &value
				break
			}
		}
	}
	if expected != nil && previous != nil && previous.Gender != nil && *expected != *previous.Gender {
		return nil
	}
	entity := Entity{ID: newID(), Name: name, Kind: "team", SportID: competition.SportID, CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Memberships: []Membership{}, Active: true, Gender: expected}
	if strings.Contains(competition.Name, "NCAA") {
		entity.Kind = "ncaa-team"
	}
	if previous != nil {
		entity = *previous
		entity.ProviderIDs = map[string]string{}
		for k, v := range previous.ProviderIDs {
			entity.ProviderIDs[k] = v
		}
		entity.Name = name
		entity.Active = true
		if entity.Gender == nil {
			entity.Gender = expected
		}
		entity.Aliases = append([]string{}, previous.Aliases...)
		if previous.Name != name {
			entity.Aliases = append(entity.Aliases, previous.Name)
		}
	}
	entity.Aliases = uniqueSorted(entity.Aliases)
	entity.ProviderIDs["thesportsdb"] = native
	includes := false
	for _, m := range entity.Memberships {
		includes = includes || (m.EntityID == competition.ID && m.Includes(now))
	}
	if !includes {
		entity.Memberships = append(append([]Membership{}, entity.Memberships...), Membership{EntityID: competition.ID, ValidFrom: now})
	}
	entity.CompetitionIDs = uniqueSorted(append(append([]string{}, entity.CompetitionIDs...), competition.ID))
	entity.Abbreviation = ProviderAbbreviation(record["strTeamShort"], native)
	if entity.Abbreviation == nil && previous != nil && previous.ProviderIDs["thesportsdb"] == native {
		entity.Abbreviation = previous.Abbreviation
	}
	sort.Strings(entity.CompetitionIDs)
	return &entity
}
func equalPtr(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
