package sportscore

import (
	"strconv"
	"strings"
)

func Contains(phrase, text string) bool {
	return strings.Contains(" "+text+" ", " "+Normalize(phrase)+" ")
}
func anyPhrase(phrases []string, text string) bool {
	for _, p := range phrases {
		if Contains(p, text) {
			return true
		}
	}
	return false
}
func in(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func gender(word string) string {
	switch word {
	case "women", "womens", "female", "feminino", "feminina", "femenino", "femenina", "femminile", "frauen", "damen":
		return "women"
	case "men", "mens", "male", "masculino", "masculina", "maschile", "herren":
		return "men"
	}
	return ""
}
func genderPermits(alias, text string, expected *string) bool {
	if expected == nil {
		return true
	}
	phrase, words := strings.Fields(Normalize(alias)), strings.Fields(text)
	if len(phrase) == 0 || len(words) < len(phrase) {
		return false
	}
	for start := 0; start <= len(words)-len(phrase); start++ {
		if strings.Join(words[start:start+len(phrase)], " ") != strings.Join(phrase, " ") {
			continue
		}
		embedded := []string{}
		for _, word := range phrase {
			if g := gender(word); g != "" {
				embedded = append(embedded, g)
			}
		}
		if len(embedded) > 0 {
			valid := true
			for _, g := range embedded {
				valid = valid && g == *expected
			}
			if valid {
				return true
			}
			continue
		}
		nearest := 3
		qualifiers := []string{}
		for _, direction := range []int{-1, 1} {
			for distance := 1; distance <= 2; distance++ {
				offset := start - distance
				if direction > 0 {
					offset = start + len(phrase) + distance - 1
				}
				if offset < 0 || offset >= len(words) {
					break
				}
				word := words[offset]
				if in([]string{"and", "or", "vs", "versus", "y", "e", "et", "und", "but", "while"}, word) {
					break
				}
				if g := gender(word); g != "" {
					if distance < nearest {
						nearest = distance
						qualifiers = []string{g}
					} else if distance == nearest {
						qualifiers = append(qualifiers, g)
					}
					break
				}
			}
		}
		if nearest == 3 {
			return true
		}
		valid := true
		for _, g := range qualifiers {
			valid = valid && g == *expected
		}
		if valid {
			return true
		}
	}
	return false
}
func swimming(text string) bool {
	if anyPhrase([]string{"adult swim", "robot", "robots", "robotic", "freestyle rap", "freestyle dance"}, text) {
		return false
	}
	explicit := anyPhrase([]string{"swimming", "swimmer", "swimmers", "swim", "backstroke", "breaststroke", "butterfly stroke", "individual medley"}, text)
	if !explicit && anyPhrase([]string{"bmx", "ski", "skiing", "snowboard", "snowboarding", "skateboarding", "wrestling", "motocross"}, text) {
		return false
	}
	distance := false
	for _, token := range strings.Fields(text) {
		for _, unit := range []string{"m", "yd", "yards", "metres", "meters"} {
			if strings.HasSuffix(token, unit) {
				if n, err := strconv.Atoi(strings.TrimSuffix(token, unit)); err == nil && n > 0 {
					distance = true
				}
			}
		}
	}
	return (explicit || (Contains("freestyle", text) && distance)) && anyPhrase([]string{"championship", "championships", "world record", "gold", "gold medal", "silver medal", "bronze medal", "medals", "swim meet", "swimming meet", "race", "relay", "olympics", "olympic games", "olympic swimming competition", "paralympics", "paralympic", "paralympic games", "paralympic swimming", "asian games", "ncaa", "world aquatics", "swimming world cup"}, text)
}
func paraSwimming(text string) bool {
	return swimming(text) && anyPhrase([]string{"para swimming", "paraswimming", "paralympic", "paralympics", "paralympic games"}, text)
}
func drumCorps(text string) bool {
	return anyPhrase([]string{"drum corps", "drum and bugle corps", "drum bugle corps", "drumcorps", "marching music"}, text) || (Contains("DCI", text) && anyPhrase([]string{"corps", "drumline", "brass", "percussion", "color guard", "colour guard", "world class", "open class", "all age", "Bluecoats", "Phantom Regiment", "Santa Clara Vanguard", "Carolina Crown", "Boston Crusaders"}, text))
}
func boa(text string) bool {
	return Contains("Bands of America", text) || (Contains("BOA", text) && (anyPhrase([]string{"marching band", "bands", "band", "marching championship", "marching competition"}, text) || (anyPhrase([]string{"BOA Class A", "BOA Class AA", "BOA Class AAA", "BOA Class AAAA"}, text) && anyPhrase([]string{"championship", "champion", "competition", "finals"}, text))))
}
func wgiDisciplines(text string) []string {
	organization := Contains("WGI", text) || Contains("Winter Guard International", text)
	result := []string{}
	if anyPhrase([]string{"winter guard", "winterguard", "indoor color guard", "indoor colour guard"}, text) || (organization && anyPhrase([]string{"color guard", "colour guard", "guard", "colorguard"}, text)) {
		result = append(result, "color-guard")
	}
	if anyPhrase([]string{"indoor percussion", "indoor drumline"}, text) || (organization && anyPhrase([]string{"percussion", "drumline", "PIA", "PIO", "PIW", "PSA", "PSO", "PSW", "PSCA", "PSCO", "PSCW"}, text)) {
		result = append(result, "percussion")
	}
	if anyPhrase([]string{"indoor winds", "winter winds", "WGI Winds"}, text) || (organization && anyPhrase([]string{"winds", "wynds", "WSA", "WSO", "WSW", "WIA", "WIO", "WIW"}, text)) {
		result = append(result, "winds")
	}
	return result
}
func wgi(text string) bool {
	return len(wgiDisciplines(text)) > 0 || Contains("Winter Guard International", text) || (Contains("WGI", text) && Contains("Sport of the Arts", text))
}
func wgiEntity(entity Entity, text string) bool {
	if !wgi(text) {
		return false
	}
	disciplines := wgiDisciplines(text)
	for _, key := range []string{"color-guard", "percussion", "winds"} {
		id := ReviewedID("competition:wgi-" + key)
		if (entity.ID == id || in(entity.CompetitionIDs, id)) && !in(disciplines, key) {
			return false
		}
	}
	if entity.Kind == "team" && in(entity.GroupPath, "Concert") {
		return Contains("concert", text)
	}
	if entity.Kind == "team" && in(entity.GroupPath, "Marching") && Contains("concert percussion", text) && !Contains("marching", text) {
		return false
	}
	return true
}
func marching(text string) bool {
	return drumCorps(text) || wgi(text) || boa(text) || Contains("marching arts", text) || Contains("marching band", text)
}
