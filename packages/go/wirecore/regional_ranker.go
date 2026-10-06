package wirecore

import (
	"sort"
	"strings"
	"unicode"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

const AmericanPoliticsDownrankSlots = 3

func normalizedTopic(value string) string {
	value = norm.NFD.String(cases.Fold().String(strings.TrimSpace(value)))
	value = strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Mn, r) {
			return -1
		}
		if r == '_' {
			return '-'
		}
		return r
	}, value)
	return strings.Join(strings.FieldsFunc(value, func(r rune) bool { return r == ' ' || r == '-' }), "-")
}
func ShouldDownrankAmericanPolitics(topics []string, reasons []ReasonCode) bool {
	for _, r := range reasons {
		if r == BreakingStory || r == WidelyDiscussed || r == SharedAcrossCommunities {
			return false
		}
	}
	normalized := map[string]bool{}
	for _, t := range topics {
		normalized[normalizedTopic(t)] = true
	}
	for _, t := range []string{"american-politics", "politics-us", "politics-usa", "united-states-politics", "us-politics", "usa-politics"} {
		if normalized[t] {
			return true
		}
	}
	us, politics := false, false
	for _, t := range []string{"america", "american", "united-states", "us", "usa"} {
		us = us || normalized[t]
	}
	for _, t := range []string{"election", "elections", "government", "political", "politics"} {
		politics = politics || normalized[t]
	}
	return us && politics
}
func DownrankAmericanPolitics[T any](items []T, topics func(T) []string, reasons func(T) []ReasonCode) []T {
	type positioned struct {
		item             T
		offset, position int
		flagged          bool
	}
	values := make([]positioned, len(items))
	for i, item := range items {
		flagged := ShouldDownrankAmericanPolitics(topics(item), reasons(item))
		position := i
		if flagged {
			position += AmericanPoliticsDownrankSlots
		}
		values[i] = positioned{item, i, position, flagged}
	}
	sort.Slice(values, func(i, j int) bool {
		a, b := values[i], values[j]
		if a.position != b.position {
			return a.position < b.position
		}
		if a.flagged != b.flagged {
			return !a.flagged
		}
		return a.offset < b.offset
	})
	result := make([]T, len(items))
	for i, v := range values {
		result[i] = v.item
	}
	return result
}
