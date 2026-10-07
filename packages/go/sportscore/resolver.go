package sportscore

import (
	"fmt"
	"sort"
	"strings"
)

type EntityIndex struct {
	Entities     []Entity
	byFirstToken map[string][]int
}

func NewEntityIndex(entities []Entity) *EntityIndex {
	index := &EntityIndex{Entities: entities, byFirstToken: map[string][]int{}}
	for offset, entity := range entities {
		if !entity.Active {
			continue
		}
		seen := map[string]bool{}
		for _, alias := range append([]string{entity.Name}, entity.Aliases...) {
			words := strings.Fields(Normalize(alias))
			if len(words) > 0 && !seen[words[0]] {
				index.byFirstToken[words[0]] = append(index.byFirstToken[words[0]], offset)
				seen[words[0]] = true
			}
		}
	}
	return index
}
func clipped(text string, limit int) string {
	r := []rune(text)
	if len(r) > limit {
		return string(r[:limit])
	}
	return text
}
func Analyze(title, summary string, catalog []Entity) ArticleAnalysis {
	return AnalyzeIndex(title, summary, NewEntityIndex(catalog))
}
func AnalyzeIndex(title, summary string, index *EntityIndex) ArticleAnalysis {
	result := ArticleAnalysis{ResolverVersion: ResolverVersion, Materiality: "reporting", Associations: []Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}
	headline := Normalize(title)
	opening := clipped(summary, 1000)
	text := Normalize(title + " " + opening)
	if Contains("boxing day", text) && anyPhrase([]string{"sale", "sales", "discount", "shopping"}, text) {
		return result
	}
	context := anyPhrase(contextTerms, text)
	sportByID := map[string]string{}
	keys := append(append([]string{}, sportKeys...), "indoor-marching-arts", "marching-arts", "swimming", "winter-sports")
	for key := range specificTokens {
		keys = append(keys, key)
	}
	for _, key := range keys {
		sportByID[ReviewedID("sport:"+key)] = key
	}
	entityByID := map[string]Entity{}
	for _, entity := range index.Entities {
		if _, ok := entityByID[entity.ID]; !ok {
			entityByID[entity.ID] = entity
		}
	}
	independent := func(entity Entity) bool {
		if entity.SportID == nil {
			return false
		}
		tokens := []string{}
		for _, token := range specificTokens[sportByID[*entity.SportID]] {
			if !in(genericLeagueLabels, Normalize(token)) && token != "fc" {
				tokens = append(tokens, token)
			}
		}
		if anyPhrase(tokens, text) {
			return true
		}
		for _, team := range index.Entities {
			if in([]string{"team", "national-side", "ncaa-team"}, team.Kind) && in(team.CompetitionIDs, entity.ID) && len(strings.Fields(Normalize(team.Name))) >= 2 && Contains(team.Name, text) {
				return true
			}
		}
		return false
	}
	sportEvidence := func(entity Entity) bool {
		if entity.Kind == "ncaa-team" && Contains(entity.Name, text) {
			return true
		}
		if entity.Name == "Los Angeles Dodgers" && Contains(entity.Name, text) && anyPhrase([]string{"three peat", "3 peat"}, text) {
			return true
		}
		sportID := entity.SportID
		if entity.Kind == "sport" {
			sportID = &entity.ID
		}
		if sportID == nil {
			return context
		}
		key := sportByID[*sportID]
		switch key {
		case "swimming":
			return swimming(text)
		case "drum-corps":
			return drumCorps(text)
		case "indoor-marching-arts":
			return wgiEntity(entity, text)
		case "marching-arts":
			return boa(text) || (entity.Kind == "team" && Contains("marching band", text))
		}
		tokens := append([]string{}, specificTokens[key]...)
		for _, competition := range index.Entities {
			if !in(entity.CompetitionIDs, competition.ID) || competition.Kind != "competition" {
				continue
			}
			generic := false
			for _, name := range append([]string{competition.Name}, competition.Aliases...) {
				generic = generic || in(genericLeagueLabels, Normalize(name))
			}
			if !generic || independent(competition) {
				tokens = append(tokens, competition.Name)
				tokens = append(tokens, competition.Aliases...)
			}
		}
		return anyPhrase(tokens, text)
	}
	offsets := map[int]bool{}
	for _, word := range strings.Fields(text) {
		for _, offset := range index.byFirstToken[word] {
			offsets[offset] = true
		}
	}
	ordered := []int{}
	for offset := range offsets {
		ordered = append(ordered, offset)
	}
	sort.Ints(ordered)
	marchingID, wgiID, drumID, swimID := ReviewedID("sport:marching-arts"), ReviewedID("sport:indoor-marching-arts"), ReviewedID("sport:drum-corps"), ReviewedID("sport:swimming")
	classes := map[string]string{}
	for n := 1; n <= 14; n++ {
		for _, prefix := range []string{"S", "SB", "SM"} {
			if prefix == "SB" && n == 10 {
				continue
			}
			code := fmt.Sprintf("%s%d", prefix, n)
			classes[ReviewedID("classification:para-swimming-"+strings.ToLower(code))] = code
		}
	}
	for _, offset := range ordered {
		entity := index.Entities[offset]
		if entity.Kind == "school" {
			continue
		}
		sportID := ""
		if entity.SportID != nil {
			sportID = *entity.SportID
		}
		if entity.ID == marchingID && !marching(text) {
			continue
		}
		if sportID == marchingID && !boa(text) && !(entity.Kind == "team" && Contains("marching band", text)) {
			continue
		}
		if (entity.ID == wgiID || sportID == wgiID) && !wgiEntity(entity, text) {
			continue
		}
		if (entity.ID == drumID || sportID == drumID) && !drumCorps(text) {
			continue
		}
		if code, ok := classes[entity.ID]; ok && (!paraSwimming(text) || !Contains(code, text)) {
			continue
		}
		if (entity.ID == swimID || sportID == swimID) && entity.ID != ReviewedID("competition:world-aquatics") && !swimming(text) {
			continue
		}
		matching := []string{}
		for _, alias := range append([]string{entity.Name}, entity.Aliases...) {
			if !Contains(alias, text) || !genderPermits(alias, text, entity.Gender) {
				continue
			}
			if entity.Kind == "team" && in([]string{drumID, wgiID, marchingID}, sportID) {
				normalized := Normalize(alias)
				longer := []string{}
				for _, other := range index.Entities {
					if other.ID != entity.ID && in([]string{"team", "ncaa-team", "national-side"}, other.Kind) && len([]rune(Normalize(other.Name))) > len([]rune(normalized)) && Contains(alias, Normalize(other.Name)) {
						longer = append(longer, Normalize(other.Name))
					}
				}
				sort.SliceStable(longer, func(i, j int) bool { return len([]rune(longer[i])) > len([]rune(longer[j])) })
				remaining := " " + text + " "
				for _, name := range longer {
					remaining = strings.ReplaceAll(remaining, " "+name+" ", " ")
				}
				if !Contains(alias, remaining) {
					continue
				}
			}
			matching = append(matching, alias)
		}
		if len(matching) == 0 {
			continue
		}
		sort.SliceStable(matching, func(i, j int) bool { return len([]rune(matching[i])) > len([]rune(matching[j])) })
		alias := matching[0]
		normalized := Normalize(alias)
		if entity.Kind == "competition" && in(genericLeagueLabels, normalized) && !independent(entity) {
			continue
		}
		requires := in(ambiguousTerms, normalized) || in([]string{"athlete", "driver", "school", "team", "national-side", "ncaa-team"}, entity.Kind)
		if requires && !sportEvidence(entity) {
			continue
		}
		if in([]string{"team", "ncaa-team", "athlete", "driver"}, entity.Kind) && anyPhrase([]string{"ammunition", "weapon", "gaming", "video game", "council", "housing budget"}, text) {
			known := false
			for _, id := range entity.CompetitionIDs {
				competition, ok := entityByID[id]
				known = known || (ok && Contains(competition.Name, text))
			}
			if !known {
				continue
			}
		}
		if in([]string{"rbr", "vcarb"}, normalized) && !anyPhrase([]string{"f1", "formula 1", "formula one"}, text) {
			continue
		}
		if in([]string{"athlete", "driver"}, entity.Kind) && len(strings.Fields(normalized)) < 2 {
			continue
		}
		if normalized == "usc" && !anyPhrase([]string{"college football", "college basketball", "quarterback", "qb"}, text) {
			continue
		}
		primary := anyPhrase(matching, headline)
		prominence := 1
		ev := []string{"name:" + alias, "summary"}
		if primary {
			prominence = 0
			ev[1] = "headline"
		}
		if context {
			ev = append(ev, "sports-context")
		}
		confidence := .98
		if requires {
			confidence = .94
		}
		result.Associations = append(result.Associations, Association{entity.ID, confidence, ev, prominence, ResolverVersion})
	}
	filtered := []Association{}
	personal := []string{"team", "ncaa-team", "national-side", "athlete", "driver"}
	for _, a := range result.Associations {
		entity := entityByID[a.EntityID]
		peers := 0
		for _, other := range result.Associations {
			peer := entityByID[other.EntityID]
			if other.Evidence[0] == a.Evidence[0] && (entity.Kind == peer.Kind || (in(personal, entity.Kind) && in(personal, peer.Kind))) {
				peers++
			}
		}
		if peers == 1 || Contains(entity.Name, text) {
			filtered = append(filtered, a)
		}
	}
	result.Associations = filtered
	appendInference := func(id string, evidence []string, prominent bool) {
		if _, ok := entityByID[id]; !ok {
			return
		}
		for _, a := range result.Associations {
			if a.EntityID == id {
				return
			}
		}
		prominence := 1
		if prominent {
			prominence = 0
		}
		result.Associations = append(result.Associations, Association{id, .94, evidence, prominence, ResolverVersion})
	}
	if marching(text) {
		appendInference(marchingID, []string{"marching-arts-context"}, marching(headline))
	}
	if wgi(text) {
		competition := ReviewedID("competition:wgi")
		organization := Contains("WGI", text) || Contains("Winter Guard International", text)
		for _, a := range result.Associations {
			entity := entityByID[a.EntityID]
			organization = organization || (entity.Kind == "team" && in(entity.CompetitionIDs, competition))
		}
		ids := []string{wgiID}
		if organization {
			ids = append(ids, competition)
			for _, key := range wgiDisciplines(text) {
				ids = append(ids, ReviewedID("competition:wgi-"+key))
			}
		}
		for _, id := range ids {
			appendInference(id, []string{"indoor-marching-arts-context"}, wgi(headline))
		}
	}
	if swimming(text) {
		ids := []string{swimID}
		for _, entry := range []struct {
			key   string
			terms []string
		}{{"olympic-swimming", []string{"olympics", "olympic games", "olympic swimming"}}, {"paralympic-swimming", []string{"paralympics", "paralympic games", "paralympic swimming"}}, {"asian-games-swimming", []string{"asian games"}}, {"ncaa-swimming", []string{"ncaa"}}} {
			if anyPhrase(entry.terms, text) {
				ids = append(ids, ReviewedID("competition:"+entry.key))
			}
		}
		if paraSwimming(text) {
			ids = append(ids, ReviewedID("competition:para-swimming"))
		}
		for _, id := range ids {
			appendInference(id, []string{"competitive-swimming-context", "stroke-or-swimming-and-competition"}, swimming(headline))
		}
	}
	sports, competitions := []string{}, []string{}
	headlineAssociation, summaryTeam, earlyCompetition := false, false, false
	for _, a := range result.Associations {
		entity := entityByID[a.EntityID]
		if entity.SportID != nil {
			sports = append(sports, *entity.SportID)
		}
		if entity.Kind == "sport" {
			sports = append(sports, entity.ID)
		}
		competitions = append(competitions, entity.CompetitionIDs...)
		if entity.Kind == "competition" {
			competitions = append(competitions, entity.ID)
		}
		headlineAssociation = headlineAssociation || a.Prominence == 0
		summaryTeam = summaryTeam || (a.Prominence == 1 && in([]string{"team", "ncaa-team", "national-side"}, entity.Kind))
		earlyCompetition = earlyCompetition || (a.Prominence == 1 && a.Confidence >= .98 && entity.Kind == "competition")
	}
	clues := map[string]bool{}
	for _, tokens := range specificTokens {
		for _, token := range tokens {
			if !in([]string{"race", "racing", "fight", "fighter", "driver", "fc", "augusta", "giro"}, token) {
				clues[token] = true
			}
		}
	}
	for _, token := range []string{"olympics", "paralympics", "anti doping", "sports regulation", "sports federation", "sports governing body", "sports governing bodies", "sports teams", "sports organisations", "sports organizations"} {
		clues[token] = true
	}
	count := 0
	for clue := range clues {
		if Contains(clue, Normalize(opening)) {
			count++
		}
	}
	result.Eligible = headlineAssociation || anyPhrase([]string{"sports", "sport", "olympics", "paralympics", "anti doping", "world cup"}, headline) || earlyCompetition || count >= 2 || (count >= 1 && summaryTeam)
	if result.Eligible {
		ancestorSet := Ancestors(set(sports), ParentIDs(index.Entities))
		result.SportIDs = []string{}
		for id := range ancestorSet {
			result.SportIDs = append(result.SportIDs, id)
		}
		sort.Strings(result.SportIDs)
		result.CompetitionIDs = uniqueSorted(competitions)
		sort.Slice(result.Associations, func(i, j int) bool {
			a, b := result.Associations[i], result.Associations[j]
			if a.Prominence != b.Prominence {
				return a.Prominence < b.Prominence
			}
			return a.EntityID < b.EntityID
		})
	} else {
		result.Associations = []Association{}
	}
	switch {
	case anyPhrase([]string{"championship", "champion", "world cup", "gold medal", "final", "playoff"}, headline):
		result.Materiality = "championship"
	case anyPhrase([]string{"clinches", "clinched", "qualifies", "qualified", "eliminated", "relegated", "promotion secured"}, headline):
		result.Materiality = "consequential-game"
	case anyPhrase([]string{"coach", "coaching", "owner", "ownership", "commissioner", "president", "governance", "governing body", "league leadership"}, headline) && anyPhrase([]string{"fired", "dismissed", "resigns", "resigned", "appointed", "appoints", "hired", "hires", "sells", "sale", "takeover", "replaced", "changes"}, headline):
		result.Materiality = "organizational-change"
	case anyPhrase([]string{"transfer", "trade", "signs", "signed", "contract"}, headline):
		result.Materiality = "transfer"
	case anyPhrase([]string{"injury", "injured", "concussion", "surgery"}, headline):
		result.Materiality = "injury"
	case anyPhrase([]string{"record", "world record", "historic"}, headline):
		result.Materiality = "record"
	case anyPhrase([]string{"suspended", "suspension", "doping", "banned", "disciplinary"}, headline):
		result.Materiality = "disciplinary"
	case anyPhrase([]string{"prediction", "predictions", "betting", "odds", "fantasy picks", "promo code", "tickets on sale"}, headline):
		result.Materiality = "routine-chatter"
	}
	return result
}

func uniqueSorted(values []string) []string {
	result := []string{}
	for value := range set(values) {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
