package wireworkercore

import (
	"regexp"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

var languageCodePattern = regexp.MustCompile(`^[a-z]{2,3}$`)

func normalizePageLanguage(raw string) string {
	code := strings.ToLower(strings.SplitN(strings.ReplaceAll(raw, "_", "-"), "-", 2)[0])
	if !languageCodePattern.MatchString(code) {
		return ""
	}
	return code
}
func validatedPageLanguage(raw, title, summary *string) *string {
	code := normalizePageLanguage(optionalText(raw))
	if code == "" {
		return nil
	}
	text := optionalText(title) + " " + optionalText(summary)
	letters := 0
	counts := map[string]int{}
	for _, c := range text {
		if !unicode.IsLetter(c) {
			continue
		}
		letters++
		switch {
		case c >= 0x3040 && c <= 0x30ff:
			counts["ja"]++
		case c >= 0x3400 && c <= 0x9fff:
			counts["zh"]++
		case c >= 0xac00 && c <= 0xd7af:
			counts["ko"]++
		case c >= 0x0400 && c <= 0x052f:
			counts["ru"]++
		case c >= 0x0600 && c <= 0x06ff || c >= 0x0750 && c <= 0x077f || c >= 0x08a0 && c <= 0x08ff:
			counts["ar"]++
		case c >= 0x0590 && c <= 0x05ff:
			counts["he"]++
		case c >= 0x0900 && c <= 0x097f:
			counts["hi"]++
		case c >= 0x0980 && c <= 0x09ff:
			counts["bn"]++
		case c >= 0x0e00 && c <= 0x0e7f:
			counts["th"]++
		}
	}
	if letters < 6 {
		return nil
	}
	accepted := false
	switch code {
	case "ja":
		accepted = counts["ja"] >= 2 || counts["zh"] >= 2
	case "zh":
		accepted = counts["zh"] >= 2 && counts["ja"] == 0
	case "ko":
		accepted = counts["ko"] >= 2
	case "ru", "uk":
		accepted = counts["ru"] >= 4
	case "ar", "fa":
		accepted = counts["ar"] >= 4
	case "he", "hi", "bn", "th":
		accepted = counts[code] >= 4
	default:
		nonLatin := 0
		for _, n := range counts {
			nonLatin += n
		}
		if nonLatin > 0 {
			return nil
		}
		words, ok := languageEvidence[code]
		if !ok {
			return nil
		}
		var folded strings.Builder
		for _, c := range norm.NFD.String(strings.ToLower(text)) {
			if !unicode.Is(unicode.Mn, c) {
				folded.WriteRune(c)
			}
		}
		tokens := map[string]bool{}
		for _, word := range strings.FieldsFunc(folded.String(), func(c rune) bool { return !unicode.IsLetter(c) }) {
			tokens[word] = true
		}
		score := func(words []string) int {
			result := 0
			for _, word := range words {
				if tokens[word] {
					result++
				}
			}
			return result
		}
		declared := score(words)
		strongest := 0
		for other, words := range languageEvidence {
			if other != code {
				strongest = max(strongest, score(words))
			}
		}
		accepted = declared >= 2 && strongest <= declared
	}
	if !accepted {
		return nil
	}
	return &code
}
