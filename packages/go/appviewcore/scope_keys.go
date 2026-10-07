package appviewcore

import (
	"sort"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func PublicationSiteKeys(scope PublicationScope) []string {
	set := map[string]bool{}
	if scope.PublicationATURI != nil {
		for _, key := range thinappviewcore.PublicationEquivalenceKeys(*scope.PublicationATURI) {
			set[key] = true
		}
	}
	for _, uri := range scope.PublicationScopeATURIs {
		if key := thinappviewcore.CanonicalPublicationATURI(uri); key != "" {
			set[key] = true
		}
	}
	for _, raw := range scope.PublicationSiteURLs {
		if normalized := thinappviewcore.NormalizeFeedURL(raw); normalized != nil {
			set[*normalized] = true
		}
		if normalized := thinappviewcore.NormalizePublicationSiteURL(raw); normalized != "" {
			set[normalized] = true
		}
	}
	result := []string{}
	for key := range set {
		result = append(result, key)
	}
	sort.Strings(result)
	return result
}
