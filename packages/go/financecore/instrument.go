package financecore

import (
	"reflect"
	"sort"
	"strings"
)

type Instrument struct {
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	Symbol            string   `json:"symbol"`
	Kind              string   `json:"kind"`
	ProviderID        string   `json:"providerID"`
	Exchange          *string  `json:"exchange,omitempty"`
	ExchangeName      *string  `json:"exchangeName,omitempty"`
	MIC               *string  `json:"mic,omitempty"`
	ShareClassFIGI    *string  `json:"shareClassFIGI,omitempty"`
	CompositeFIGI     *string  `json:"compositeFIGI,omitempty"`
	Currency          *string  `json:"currency,omitempty"`
	Aliases           []string `json:"aliases"`
	SectorIDs         []string `json:"sectorIDs"`
	TradingViewSymbol *string  `json:"tradingViewSymbol,omitempty"`
	IsActive          bool     `json:"isActive"`
}
type ReviewedMetadata struct {
	InstrumentID       string   `json:"instrumentID"`
	ExpectedProviderID string   `json:"expectedProviderID"`
	ExpectedSymbol     string   `json:"expectedSymbol"`
	TradingViewSymbol  *string  `json:"tradingViewSymbol"`
	SectorIDs          []string `json:"sectorIDs"`
	IndustryIDs        []string `json:"industryIDs"`
	Aliases            []string `json:"aliases"`
	VerifiedDomains    []string `json:"verifiedDomains"`
	VerifiedAccounts   []string `json:"verifiedAccounts"`
	EvidenceURL        string   `json:"evidenceURL"`
}
type ProviderPolicy struct{ CryptoEnabled, ReviewedCryptoEnabled bool }

func NewProviderPolicy(env map[string]string) ProviderPolicy {
	return ProviderPolicy{strings.EqualFold(env["FINANCE_CRYPTO_CATALOG_ENABLED"], "true"), strings.EqualFold(env["FINANCE_REVIEWED_CRYPTO_CATALOG_ENABLED"], "true")}
}
func (p ProviderPolicy) Permits(i Instrument) bool {
	if strings.ToLower(i.Kind) != "crypto" {
		return true
	}
	for _, reference := range ReviewedInstruments() {
		if reference.Kind == "crypto" && reflect.DeepEqual(reference, i) {
			return p.ReviewedCryptoEnabled
		}
	}
	return p.CryptoEnabled
}
func (p ProviderPolicy) Filter(values []Instrument) []Instrument {
	result := []Instrument{}
	for _, value := range values {
		if p.Permits(value) {
			result = append(result, value)
		}
	}
	return result
}
func (p ProviderPolicy) Revision() string {
	revision := "providers-reference-v1"
	if p.CryptoEnabled {
		revision = "providers-crypto-v1"
	}
	if p.ReviewedCryptoEnabled {
		revision += ":reviewed-crypto-v1"
	}
	return revision
}
func ApplyReviewedMetadata(i Instrument) Instrument {
	etf := map[string]bool{"BBG000BDTBL9": true, "BBG000BSWKH7": true, "BBG0015VYNT4": true, "BBG000BVZ4F5": true}
	if !i.IsActive {
		if etf[i.ProviderID] {
			i.Kind = "etf"
		}
		i.TradingViewSymbol = nil
		return i
	}
	for _, entry := range ReviewedEntries() {
		if entry.InstrumentID != i.ID || entry.ExpectedProviderID != i.ProviderID || entry.ExpectedSymbol != i.Symbol || entry.EvidenceURL == "" {
			continue
		}
		valid := true
		for _, id := range entry.SectorIDs {
			if _, ok := sectorKeywords[id]; !ok {
				valid = false
			}
		}
		if !valid {
			continue
		}
		if etf[i.ProviderID] {
			i.Kind = "etf"
		}
		i.Aliases = sortedUnique(append(append([]string{}, i.Aliases...), entry.Aliases...))
		if len(entry.SectorIDs) > 0 {
			i.SectorIDs = append([]string{}, entry.SectorIDs...)
		}
		i.TradingViewSymbol = entry.TradingViewSymbol
		return i
	}
	return i
}
func VerifiedInstrumentIDs(domain, account string) []string {
	result := []string{}
	for _, entry := range ReviewedEntries() {
		if entry.EvidenceURL == "" {
			continue
		}
		for _, value := range entry.VerifiedDomains {
			if domain != "" && strings.EqualFold(value, domain) {
				result = append(result, entry.InstrumentID)
				break
			}
		}
		if account != "" && sliceHas(entry.VerifiedAccounts, account) && !sliceHas(result, entry.InstrumentID) {
			result = append(result, entry.InstrumentID)
		}
	}
	return result
}
func sortedUnique(values []string) []string {
	set := map[string]bool{}
	for _, v := range values {
		set[v] = true
	}
	result := []string{}
	for v := range set {
		result = append(result, v)
	}
	sort.Strings(result)
	return result
}
func sliceHas(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
