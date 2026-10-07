package publicationcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/url"
	"sort"
	"strings"
)

func NormalizeATRepoParam(raw string) string {
	s := strings.TrimPrefix(strings.TrimSpace(raw), "@")
	for i := 0; i < 3; i++ {
		if strings.HasPrefix(s, "did:") {
			return s
		}
		if strings.HasPrefix(s, "at://") {
			parts := strings.Split(strings.TrimPrefix(s, "at://"), "/")
			if len(parts) == 3 {
				auth, col := parts[0], parts[1]
				for j := 0; j < 3; j++ {
					if d, e := url.PathUnescape(auth); e == nil {
						auth = d
					}
					if d, e := url.PathUnescape(col); e == nil {
						col = d
					}
				}
				decoded := "at://" + auth + "/" + col + "/" + parts[2]
				if decoded != s {
					s = decoded
					continue
				}
			}
		}
		decoded, e := url.PathUnescape(s)
		if e != nil || decoded == s {
			return s
		}
		s = decoded
	}
	return s
}
func LookupKeys(raw string) []string {
	keys := map[string]bool{raw: true}
	add := func(value string) {
		normalized := NormalizeATRepoParam(value)
		keys[normalized] = true
		if strings.HasPrefix(normalized, "at://") {
			parts := strings.Split(strings.TrimPrefix(normalized, "at://"), "/")
			if len(parts) == 3 {
				switch parts[1] {
				case "site.standard.publication":
					keys["at://"+parts[0]+"/com.standard.publication/"+parts[2]] = true
				case "com.standard.publication":
					keys["at://"+parts[0]+"/site.standard.publication/"+parts[2]] = true
				}
			}
		}
	}
	normalized := NormalizeATRepoParam(raw)
	add(normalized)
	if canonical := thinappviewcore.CanonicalPublicationATURI(normalized); canonical != "" {
		add(canonical)
	}
	out := []string{}
	for key := range keys {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}
func IDsMatch(a, b string) bool {
	keys := map[string]bool{}
	for _, key := range LookupKeys(a) {
		keys[NormalizeATRepoParam(key)] = true
	}
	for _, key := range LookupKeys(b) {
		if keys[NormalizeATRepoParam(key)] {
			return true
		}
	}
	return false
}
func RepoDID(id string) string {
	normal := NormalizeATRepoParam(id)
	if strings.HasPrefix(normal, "at://") {
		parts := strings.Split(strings.TrimPrefix(normal, "at://"), "/")
		if len(parts) == 3 {
			return parts[0]
		}
	}
	return normal
}
func owns(row DiscoveredRow, viewer string) bool {
	normalize := func(s string) string {
		s = NormalizeATRepoParam(s)
		if strings.HasPrefix(strings.ToLower(s), "did:plc:") {
			return strings.ToLower(s)
		}
		return s
	}
	return viewer != "" && (normalize(RepoDID(row.PublicationID)) == normalize(viewer) || normalize(row.AuthorDID) == normalize(viewer))
}
func MatchKeys(row DiscoveredRow) []string {
	keys := LookupKeys(row.PublicationID)
	if row.SubscriptionPublicationID != nil {
		keys = append(keys, LookupKeys(*row.SubscriptionPublicationID)...)
	}
	return keys
}
