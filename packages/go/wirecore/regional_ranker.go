package wirecore

// Moves ordinary US-politics stories by three virtual slots while retaining breaking,
// widely discussed, and cross-community stories. Stable virtual-position and original-
// offset tie-breaks preserve deterministic order.

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
	value = strings.Map(func(character rune) rune {
		if unicode.Is(unicode.Mn, character) {
			return -1
		}
		if character == '_' {
			return '-'
		}
		return character
	}, value)
	return strings.Join(strings.FieldsFunc(value, func(character rune) bool { return character == ' ' || character == '-' }), "-")
}

// ShouldDownrankAmericanPolitics flags US-politics topics unless breaking, widely-
// discussed, or cross-community evidence exempts them.
func ShouldDownrankAmericanPolitics(topics []string, reasons []ReasonCode) bool {
	for _, reasonCode := range reasons {
		if reasonCode == BreakingStory || reasonCode == WidelyDiscussed || reasonCode == SharedAcrossCommunities {
			return false
		}
	}
	normalized := map[string]bool{}
	for _, topic := range topics {
		normalized[normalizedTopic(topic)] = true
	}
	for _, topic := range []string{"american-politics", "politics-us", "politics-usa", "united-states-politics", "us-politics", "usa-politics"} {
		if normalized[topic] {
			return true
		}
	}
	us, politics := false, false
	for _, topic := range []string{"america", "american", "united-states", "us", "usa"} {
		us = us || normalized[topic]
	}
	for _, topic := range []string{"election", "elections", "government", "political", "politics"} {
		politics = politics || normalized[topic]
	}
	return us && politics
}

// DownrankAmericanPolitics orders items by virtual positions shifted three slots for
// flagged stories without dropping items.
func DownrankAmericanPolitics[T any](items []T, topics func(T) []string, reasons func(T) []ReasonCode) []T {
	type positioned struct {
		item             T
		offset, position int
		flagged          bool
	}
	values := make([]positioned, len(items))
	for itemIndex, item := range items {
		flagged := ShouldDownrankAmericanPolitics(topics(item), reasons(item))
		position := itemIndex
		if flagged {
			position += AmericanPoliticsDownrankSlots
		}
		values[itemIndex] = positioned{item, itemIndex, position, flagged}
	}
	sort.Slice(values, func(itemIndex, comparisonIndex int) bool {
		leftItem, rightItem := values[itemIndex], values[comparisonIndex]
		if leftItem.position != rightItem.position {
			return leftItem.position < rightItem.position
		}
		if leftItem.flagged != rightItem.flagged {
			return !leftItem.flagged
		}
		return leftItem.offset < rightItem.offset
	})
	result := make([]T, len(items))
	for itemIndex, positionedItem := range values {
		result[itemIndex] = positionedItem.item
	}
	return result
}
