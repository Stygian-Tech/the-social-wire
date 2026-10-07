package topicreadcore

import (
	_ "embed"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"math"
	"sort"
	"strings"
)

const FinanceNamedVersion = "finance-named-feeds-v4"

type FinanceSector struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Keywords []string `json:"keywords"`
}

//go:embed finance_taxonomy.json
var financeTaxonomyJSON []byte

func financeTaxonomy() struct{ Sectors, Industries []FinanceSector } {
	var taxonomy struct{ Sectors, Industries []FinanceSector }
	if err := json.Unmarshal(financeTaxonomyJSON, &taxonomy); err != nil {
		panic(err)
	}
	return taxonomy
}
func FinanceSectors() []FinanceSector { return financeTaxonomy().Sectors }

type FinanceDefinition struct {
	ID            string   `json:"id"`
	Title         string   `json:"title"`
	Kind          string   `json:"kind"`
	AssetKind     *string  `json:"assetKind,omitempty"`
	InstrumentIDs []string `json:"instrumentIDs"`
	SectorIDs     []string `json:"sectorIDs"`
	Description   string   `json:"description"`
}

func financeAsset(i financecore.Instrument) string {
	kind := strings.ToLower(strings.TrimSpace(i.Kind))
	switch kind {
	case "etf", "crypto", "index", "commodity":
		return kind
	default:
		return "stock"
	}
}
func financeNamedSupported(i financecore.Instrument) bool {
	if !i.IsActive {
		return false
	}
	switch strings.ToLower(strings.TrimSpace(i.Kind)) {
	case "common stock", "equity", "stock", "preferred stock", "depositary receipt", "adr", "reit", "etf", "mutual fund", "closed-end fund", "closed end fund", "crypto", "index":
		return true
	}
	return false
}
func FinanceDefinitions(instruments []financecore.Instrument) []FinanceDefinition {
	active := []financecore.Instrument{}
	ids := map[string]bool{}
	for _, i := range instruments {
		if financeNamedSupported(i) {
			active = append(active, i)
			ids[i.ID] = true
		}
	}
	definition := func(id, title, kind, description string) FinanceDefinition {
		return FinanceDefinition{ID: id, Title: title, Kind: kind, InstrumentIDs: []string{}, SectorIDs: []string{}, Description: description}
	}
	feeds := []FinanceDefinition{definition("finance", "Finance", "all", "Global financial news, personalized to your interests.")}
	taxonomy := financeTaxonomy()
	for _, sector := range taxonomy.Sectors {
		f := definition("industry:"+sector.ID, sector.Name, "industry", "Financial reporting about "+sector.Name+".")
		f.SectorIDs = []string{sector.ID}
		for _, i := range active {
			for _, sid := range i.SectorIDs {
				if sid == sector.ID {
					f.InstrumentIDs = append(f.InstrumentIDs, i.ID)
					break
				}
			}
		}
		sort.Strings(f.InstrumentIDs)
		feeds = append(feeds, f)
	}
	for _, industry := range taxonomy.Industries {
		f := definition("industry:"+industry.ID, industry.Name, "industry", "Financial reporting about "+industry.Name+".")
		for _, entry := range financecore.ReviewedEntries() {
			if !ids[entry.InstrumentID] {
				continue
			}
			for _, id := range entry.IndustryIDs {
				if id == industry.ID {
					f.InstrumentIDs = append(f.InstrumentIDs, entry.InstrumentID)
					break
				}
			}
		}
		feeds = append(feeds, f)
	}
	for _, group := range []struct {
		id, title string
		figis     []string
	}{{"faang", "FAANG", []string{"BBG000B9Y5X2", "BBG000BVPV84", "BBG009S39JX6", "BBG000MM2P62", "BBG000CL9VN6"}}, {"mag7", "Mag7", []string{"BBG000B9Y5X2", "BBG000BPH459", "BBG000BVPV84", "BBG009S39JX6", "BBG000MM2P62", "BBG000BBJQV0", "BBG000N9MNX3"}}} {
		f := definition("group:"+group.id, group.title, "group", "Stories associated with the reviewed "+group.title+" members.")
		complete := true
		for _, figi := range group.figis {
			id := financecore.InstrumentID("openfigi", figi)
			complete = complete && ids[id]
			f.InstrumentIDs = append(f.InstrumentIDs, id)
		}
		if complete {
			feeds = append(feeds, f)
		}
	}
	for _, asset := range []struct{ kind, title string }{{"etf", "ETFs"}, {"crypto", "Crypto"}, {"index", "Indices"}} {
		f := definition("asset:"+asset.kind, asset.title, "asset", "Stories associated with supported "+asset.title+".")
		f.AssetKind = &asset.kind
		for _, i := range active {
			if financeAsset(i) == asset.kind {
				f.InstrumentIDs = append(f.InstrumentIDs, i.ID)
			}
		}
		sort.Strings(f.InstrumentIDs)
		if len(f.InstrumentIDs) > 0 {
			feeds = append(feeds, f)
		}
	}
	exchange := func(i financecore.Instrument) string {
		if i.Exchange != nil {
			return *i.Exchange
		}
		return ""
	}
	sort.Slice(active, func(i, j int) bool {
		a, b := active[i], active[j]
		if a.Symbol != b.Symbol {
			return a.Symbol < b.Symbol
		}
		if exchange(a) != exchange(b) {
			return exchange(a) < exchange(b)
		}
		return a.ID < b.ID
	})
	for _, i := range active {
		title := "$" + i.Symbol + " · " + i.Name
		if label := financeExchangeLabel(i); label != "" {
			title += " · " + label
		}
		f := definition("instrument:"+i.ID, title, "instrument", "Stories associated with this specific security.")
		asset := financeAsset(i)
		f.AssetKind = &asset
		f.InstrumentIDs = []string{i.ID}
		feeds = append(feeds, f)
	}
	return feeds
}
func FinanceNamedRevision(instruments []financecore.Instrument) string {
	defs := FinanceDefinitions(instruments)
	sort.Slice(defs, func(i, j int) bool { return defs[i].ID < defs[j].ID })
	values := []string{FinanceNamedVersion, financecore.ReviewedMetadataVersion, "finance-curated-securities-v2", financecore.ResolverVersion}
	for _, d := range defs {
		sort.Strings(d.InstrumentIDs)
		sort.Strings(d.SectorIDs)
		values = append(values, d.ID+"|instruments="+strings.Join(d.InstrumentIDs, ",")+"|sectors="+strings.Join(d.SectorIDs, ","))
	}
	return financecore.PreferenceFingerprint(values, nil)
}
func (d FinanceDefinition) Matches(a financecore.ArticleAnalysis, title string, summary *string) bool {
	if !a.Eligible || a.ResolverVersion == nil || *a.ResolverVersion != financecore.ResolverVersion {
		return false
	}
	if d.ID == "finance" {
		return true
	}
	association := false
	for _, match := range a.Associations {
		if math.IsNaN(match.Confidence) || math.IsInf(match.Confidence, 0) || match.Confidence < .9 || match.Confidence > 1 || match.ResolverVersion != financecore.ResolverVersion {
			continue
		}
		for _, id := range d.InstrumentIDs {
			association = association || id == match.InstrumentID
		}
	}
	body := ""
	if summary != nil {
		body = *summary
	}
	text, finance := financecore.TopicEvidence(title, body)
	has := func(words []string) bool {
		for _, word := range words {
			if financecore.ContainsTopic(word, text) {
				return true
			}
		}
		return false
	}
	for _, industry := range financeTaxonomy().Industries {
		if d.ID != "industry:"+industry.ID {
			continue
		}
		if !association && industry.ID == "oil-gas" && has([]string{"cooking oil", "vegetable oil", "olive oil", "palm oil"}) {
			return false
		}
		if !association && industry.ID == "mining" && has([]string{"bitcoin", "cryptocurrency", "crypto mining"}) {
			return false
		}
		headline := false
		lead, _ := financecore.TopicEvidence("", body)
		lead = strings.TrimSpace(lead)
		for _, prefix := range []string{"the ", "a ", "an ", "small ", "large ", "global ", "major ", "leading "} {
			lead = strings.TrimPrefix(lead, prefix)
		}
		leadMatch := false
		for _, word := range industry.Keywords {
			headline = headline || financecore.ContainsTopic(word, strings.ToLower(title))
			leadMatch = leadMatch || lead == word || strings.HasPrefix(lead, word+" ")
		}
		return association || (finance && (headline || leadMatch))
	}
	if !association && d.ID == "industry:energy" && has([]string{"cooking oil", "vegetable oil", "olive oil", "palm oil"}) {
		return false
	}
	if !association && d.ID == "industry:materials" && has([]string{"bitcoin", "cryptocurrency", "crypto mining"}) {
		return false
	}
	for _, id := range d.SectorIDs {
		for _, actual := range a.SectorIDs {
			if id == actual {
				return true
			}
		}
	}
	return association
}
func financeCryptoStory(itemTitle string, summary *string, a financecore.ArticleAnalysis, catalog []financecore.Instrument) bool {
	crypto := map[string]bool{}
	for _, i := range catalog {
		if financeAsset(i) == "crypto" {
			crypto[i.ID] = true
		}
	}
	for _, match := range a.Associations {
		if crypto[match.InstrumentID] && match.Confidence >= .9 && match.Confidence <= 1 && match.ResolverVersion == financecore.ResolverVersion {
			return true
		}
	}
	body := ""
	if summary != nil {
		body = *summary
	}
	text, _ := financecore.TopicEvidence(itemTitle, body)
	for _, word := range []string{"cryptocurrency", "cryptocurrencies", "crypto", "bitcoin", "ethereum", "stablecoin", "stablecoins"} {
		if financecore.ContainsTopic(word, text) {
			return true
		}
	}
	return false
}

func financeExchangeLabel(i financecore.Instrument) string {
	if i.Exchange == nil || *i.Exchange == "" {
		if i.ExchangeName != nil {
			return *i.ExchangeName
		}
		return ""
	}
	if i.ExchangeName != nil {
		return *i.ExchangeName + " (" + *i.Exchange + ")"
	}
	return "Exchange: " + *i.Exchange
}
