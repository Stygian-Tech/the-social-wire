package publicationcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/url"
	"sort"
	"strings"
	"time"
)

func PreferencesByID(prefs []PreferenceRecord) map[string]PreferenceRecord {
	rows := append([]PreferenceRecord(nil), prefs...)
	sort.Slice(rows, func(i, j int) bool { return rows[i].URI < rows[j].URI })
	byID := map[string]PreferenceRecord{}
	for _, p := range rows {
		byID[p.PublicationID] = p
	}
	return byID
}
func FilterHidden(rows []DiscoveredRow, prefs []PreferenceRecord) []DiscoveredRow {
	out := []DiscoveredRow{}
	effective := PreferencesByID(prefs)
	for _, row := range rows {
		hidden := false
		for _, pref := range effective {
			if value, _ := pref.Value["hidden"].(bool); value && IDsMatch(row.PublicationID, pref.PublicationID) {
				hidden = true
				break
			}
		}
		if !hidden {
			out = append(out, row)
		}
	}
	return out
}
func Segment(rows []DiscoveredRow, viewer string, subscriptions []string) (subscribed, following []DiscoveredRow) {
	subscribed, following = []DiscoveredRow{}, []DiscoveredRow{}
	if viewer == "" {
		return
	}
	keys := map[string]bool{}
	for _, id := range subscriptions {
		for _, key := range LookupKeys(id) {
			keys[key] = true
		}
	}
	for _, row := range rows {
		included := owns(row, viewer) && row.SubscriptionPublicationID != nil
		for _, key := range MatchKeys(row) {
			included = included || keys[key]
		}
		if included {
			subscribed = append(subscribed, row)
		} else {
			following = append(following, row)
		}
	}
	return
}
func MergeSubscribed(subscribed, rss, orphan []DiscoveredRow) []DiscoveredRow {
	out := append([]DiscoveredRow{}, subscribed...)
	seen := map[string]bool{}
	for _, row := range out {
		seen[row.PublicationID] = true
	}
	for _, rows := range [][]DiscoveredRow{rss, orphan} {
		for _, row := range rows {
			if !seen[row.PublicationID] {
				out = append(out, row)
				seen[row.PublicationID] = true
			}
		}
	}
	return out
}
func RSSRows(records []gatewaycore.RepoRecord, at time.Time) []DiscoveredRow {
	out := []DiscoveredRow{}
	seen := map[string]bool{}
	for _, record := range records {
		value := map[string]any{}
		raw, _ := json.Marshal(record.Value)
		json.Unmarshal(raw, &value)
		get := func(key string) string { s, _ := value[key].(string); return strings.TrimSpace(s) }
		if strings.EqualFold(get("category"), "podcast") {
			continue
		}
		source := strings.ToLower(get("sourceType"))
		if source != "" && source != "rss" {
			continue
		}
		normalized := thinappviewcore.NormalizeFeedURL(get("feedUrl"))
		if normalized == nil {
			continue
		}
		id := thinappviewcore.RSSPublicationID(*normalized)
		if seen[id] {
			continue
		}
		seen[id] = true
		u, _ := url.Parse(*normalized)
		title := get("customTitle")
		if title == "" {
			title = get("title")
		}
		if title == "" {
			title = u.Hostname()
		}
		icon := get("customIconUrl")
		if icon == "" {
			site := get("siteUrl")
			if site == "" {
				site = *normalized
			}
			if base, e := url.Parse(site); e == nil && base.Host != "" {
				icon = base.Scheme + "://" + base.Host + "/favicon.ico"
			}
		}
		var image *string
		if icon != "" {
			image = &icon
		}
		handle := "RSS"
		uri := record.URI
		out = append(out, DiscoveredRow{PublicationID: id, SubscriptionPublicationID: &uri, AuthorDID: thinappviewcore.RSSAuthorDID, AuthorHandle: &handle, Title: title, IconURL: image, DiscoveredAt: at})
	}
	return out
}
