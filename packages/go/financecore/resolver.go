package financecore

import (
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// ContainsTopic uses Unicode letter/number boundaries; ambiguous isolated nouns cannot
// admit an article. Summary evidence is restricted to its opening two sentences.
func ContainsTopic(needle, text string) bool {
	needle = strings.ToLower(needle)
	if needle == "" {
		return false
	}
	for start := 0; start < len(text); {
		offset := strings.Index(text[start:], needle)
		if offset < 0 {
			return false
		}
		left := start + offset
		right := left + len(needle)
		before, after := []rune(text[:left]), []rune(text[right:])
		boundary := func(values []rune, last bool) bool {
			if len(values) == 0 {
				return true
			}
			r := values[0]
			if last {
				r = values[len(values)-1]
			}
			return !unicode.IsLetter(r) && !unicode.IsNumber(r)
		}
		if boundary(before, true) && boundary(after, false) {
			return true
		}
		start = right
	}
	return false
}
func has(words []string, text string) bool {
	for _, word := range words {
		if ContainsTopic(word, text) {
			return true
		}
	}
	return false
}
func short(text string, limit int) string {
	r := []rune(text)
	if len(r) > limit {
		return string(r[:limit])
	}
	return text
}

type topicEvidence struct {
	text              string
	finance, business bool
	sectors           []string
}

var sentenceBreak = regexp.MustCompile(`[.!?]\s+|\n+`)

func evidence(title, summary string) topicEvidence {
	headline := strings.ToLower(title)
	lead := short(strings.ToLower(summary), 600)
	for _, marker := range []string{"related stories:", "related articles:", "you may also like", "read more:", "subscribe for", "subscribe to our", "subscribe to the", "subscribe now", "this article originally appeared"} {
		if index := strings.Index(lead, marker); index >= 0 {
			lead = lead[:index]
		}
	}
	sentences := []string{}
	for _, sentence := range sentenceBreak.Split(lead, -1) {
		if trimmed := strings.TrimSpace(sentence); trimmed != "" {
			sentences = append(sentences, trimmed)
			if len(sentences) == 2 {
				break
			}
		}
	}
	segments := append([]string{headline}, sentences...)
	sportingHeadline := has([]string{"hit tons", "wins toss", "win toss", "innings", "wickets", "batting", "bowling figures"}, headline) || (has([]string{"cricket"}, headline) && has([]string{"wins", "win", "defeated", "match", "tournament"}, headline))
	sportingLead := false
	for _, segment := range sentences {
		sportingLead = sportingLead || (has([]string{"innings", "wickets", "batting", "bowling"}, segment) && has([]string{"runs", "defeated", "match", "cricket", "team"}, segment))
	}
	financialHeadline := has(strongPhrases, headline) || has(strongTerms, headline) || has([]string{"profit", "profits", "funding", "investment", "salary cap", "sponsorship deal", "team valuation"}, headline)
	incidentalSports := (sportingHeadline || sportingLead) && !financialHeadline
	result := topicEvidence{text: strings.Join(segments, " "), sectors: []string{}}
	for _, segment := range segments {
		result.business = result.business || (has(businessTerms, segment) && !incidentalSports)
		if incidentalSports {
			continue
		}
		matched := []string{}
		for id, keywords := range sectorKeywords {
			if has(keywords, segment) {
				matched = append(matched, id)
			}
		}
		sectorBusiness := len(matched) > 0 && (has([]string{"industry", "sector", "company", "business", "sales", "revenue", "earnings", "investment", "exports", "imports", "manufacturers", "firms"}, segment) || has([]string{"industrial production", "oil production", "oil supply", "oil demand", "natural gas production", "natural gas supply", "retail sales", "housing prices", "insurance premiums", "bank lending", "semiconductor supply", "pharmaceutical supply"}, segment))
		if sectorBusiness {
			result.sectors = append(result.sectors, matched...)
		}
		operating := has([]string{"industry", "sector", "company", "business", "manufacturers", "firms"}, segment) && has([]string{"prices", "costs", "sales", "production", "supply", "demand", "investment", "exports", "imports"}, segment)
		inflation := has([]string{"inflation"}, segment) && has([]string{"report", "reporting", "prices", "economic", "economy", "rises", "falls", "slows", "growth"}, segment)
		fiscal := has([]string{"fiscal", "tariff", "tariffs"}, segment) && has([]string{"budget", "government", "trade", "imports", "exports", "tax", "taxes", "borrowing"}, segment)
		result.finance = result.finance || has(strongPhrases, segment) || has(strongTerms, segment) || sectorBusiness || operating || inflation || fiscal
	}
	result.sectors = sortedUnique(result.sectors)
	return result
}
func Analyze(title, summary string, structured, verified []string, catalog []Instrument) ArticleAnalysis {
	version := ResolverVersion
	result := ArticleAnalysis{ResolverVersion: &version, Materiality: "reporting", Associations: []Association{}, SectorIDs: []string{}, MacroTopics: []string{}}
	topic := evidence(title, summary)
	text := topic.text
	headline := strings.ToLower(title)
	macro := map[string][]string{"inflation": {"inflation", "consumer prices"}, "monetary-policy": {"interest rate", "central bank", "monetary policy"}, "growth": {"gdp", "economic growth", "recession"}, "employment": {"unemployment", "employment report", "jobs report"}, "trade": {"tariff", "trade deficit", "trade surplus"}, "fiscal-policy": {"fiscal", "government budget"}}
	if !topic.finance && !topic.business && !has([]string{"announces", "launches"}, text) && len(structured) == 0 && len(verified) == 0 {
		return result
	}
	result.MacroTopics = []string{}
	for key, words := range macro {
		if has(words, text) {
			result.MacroTopics = append(result.MacroTopics, key)
		}
	}
	sort.Strings(result.MacroTopics)
	symbols, names, qualified := map[string]int{}, map[string]int{}, map[string]int{}
	for _, i := range catalog {
		if !i.IsActive {
			continue
		}
		symbols[strings.ToLower(i.Symbol)]++
		lowerNames := []string{}
		for _, name := range append([]string{i.Name}, i.Aliases...) {
			lowerNames = append(lowerNames, strings.ToLower(name))
		}
		for _, name := range sortedUnique(lowerNames) {
			names[name]++
		}
		if i.Exchange != nil {
			qualified[strings.ToLower(*i.Exchange+":"+i.Symbol)]++
		}
	}
	sectors := append([]string{}, topic.sectors...)
	for _, i := range catalog {
		if !i.IsActive {
			continue
		}
		ev := []string{}
		if sliceHas(structured, i.ID) {
			ev = append(ev, "structured-metadata")
		}
		if sliceHas(verified, i.ID) {
			ev = append(ev, "verified-source")
		}
		nameText := text
		if i.ProviderID == "BBG000B9Y5X2" && i.ID == InstrumentID("openfigi", "BBG000B9Y5X2") {
			for _, phrase := range []string{"apple martin", "apple pie", "apple juice", "apple cider", "apple sauce", "apple butter", "apple orchard", "apple harvest", "apple growers", "apple fruit"} {
				nameText = strings.ReplaceAll(nameText, phrase, " ")
			}
		}
		nameMatch := false
		for _, name := range append([]string{i.Name}, i.Aliases...) {
			if (topic.finance || topic.business) && len([]rune(name)) >= 4 && names[strings.ToLower(name)] == 1 && ContainsTopic(name, nameText) {
				nameMatch = true
			}
		}
		if nameMatch {
			ev = append(ev, "name-or-alias")
		}
		qualMatch := false
		if i.Exchange != nil {
			q := strings.ToLower(*i.Exchange + ":" + i.Symbol)
			qualMatch = qualified[q] == 1 && ContainsTopic(q, text)
		}
		if topic.finance && (qualMatch || (symbols[strings.ToLower(i.Symbol)] == 1 && ContainsTopic("$"+i.Symbol, text))) {
			ev = append(ev, "contextual-ticker")
		}
		if len(ev) == 0 {
			continue
		}
		confidence := .9
		if nameMatch {
			confidence = .95
		}
		if sliceHas(ev, "structured-metadata") || sliceHas(ev, "verified-source") {
			confidence = 1
		}
		prominence := 1
		if has(append(append([]string{i.Name}, i.Aliases...), "$"+i.Symbol), headline) {
			prominence = 0
		}
		result.Associations = append(result.Associations, Association{i.ID, confidence, ev, prominence, ResolverVersion})
		sectors = append(sectors, i.SectorIDs...)
	}
	sort.Slice(result.Associations, func(i, j int) bool {
		a, b := result.Associations[i], result.Associations[j]
		if a.Prominence != b.Prominence {
			return a.Prominence < b.Prominence
		}
		return a.InstrumentID < b.InstrumentID
	})
	result.SectorIDs = sortedUnique(sectors)
	result.Eligible = topic.finance || len(result.Associations) > 0
	definitions := []struct {
		materiality string
		words       []string
	}{{"earnings", []string{"earnings", "revenue"}}, {"filing", []string{"filing", "10-k", "10-q"}}, {"merger", []string{"merger", "acquisition"}}, {"regulation", []string{"regulation"}}, {"leadership", []string{"ceo", "chief executive", "leadership"}}, {"price-chatter", []string{"price target", "stock rises", "stock falls"}}, {"announcement", []string{"announces", "launches"}}}
	for _, definition := range definitions {
		if has(definition.words, text) {
			result.Materiality = definition.materiality
			break
		}
	}
	return result
}
