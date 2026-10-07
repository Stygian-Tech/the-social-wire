package wirecore

// Allocates deduplicated ranked stories to lead stories, publication panels, reason rails,
// and general stories in deterministic order. Trending is a separate view allowed to
// repeat allocated stories. Account highlights require distinct-story/speaker evidence and
// deterministic tie-breaks.

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

const EditionVersion = "wire-edition-v2"

// ItemSource contains publisher display metadata and optional canonical publication
// identity.
type ItemSource struct {
	Name           string  `json:"name"`
	Domain         string  `json:"domain"`
	Publication    *string `json:"publication,omitempty"`
	Author         *string `json:"author,omitempty"`
	PublicationKey *string `json:"publicationKey,omitempty"`
	HomepageURL    *string `json:"homepageUrl,omitempty"`
	IconURL        *string `json:"iconUrl,omitempty"`
}

// FeedItem is the serving article shape; JSON loading bounds reasons to two and provenance
// to eight.
type FeedItem struct {
	ItemID            string       `json:"itemId"`
	CanonicalURL      string       `json:"canonicalUrl"`
	RepresentativeURI *string      `json:"representativeUri,omitempty"`
	Title             string       `json:"title"`
	Summary           *string      `json:"summary,omitempty"`
	PublishedAt       *time.Time   `json:"publishedAt,omitempty"`
	ThumbnailURL      *string      `json:"thumbnailUrl,omitempty"`
	Source            ItemSource   `json:"source"`
	Reasons           []ReasonCode `json:"reasons"`
	Provenance        []string     `json:"provenance"`
}

// UnmarshalJSON decodes the shared wire representation while enforcing this type’s
// compatibility rules.
func (item *FeedItem) UnmarshalJSON(data []byte) error {
	type raw FeedItem
	var value raw
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*item = FeedItem(value)
	item.Reasons = append([]ReasonCode{}, item.Reasons[:min(2, len(item.Reasons))]...)
	item.Provenance = append([]string{}, item.Provenance[:min(8, len(item.Provenance))]...)
	return nil
}

// EditionPublication is a publication spotlight identity and its serving metadata.
type EditionPublication struct {
	Key         string  `json:"key"`
	ID          *string `json:"id,omitempty"`
	Name        string  `json:"name"`
	Domain      string  `json:"domain"`
	HomepageURL *string `json:"homepageUrl,omitempty"`
	IconURL     *string `json:"iconUrl,omitempty"`
}

// PublicationPanel groups two to three unallocated stories from one publication.
type PublicationPanel struct {
	Publication EditionPublication `json:"publication"`
	Stories     []FeedItem         `json:"stories"`
}

// StoryRail groups four to ten unallocated stories sharing a ranking reason.
type StoryRail struct {
	ID      string     `json:"id"`
	Title   string     `json:"title"`
	Reason  ReasonCode `json:"reason"`
	Stories []FeedItem `json:"stories"`
}

// TalkedAboutAccount contains the serving profile fields of a highlighted account.
type TalkedAboutAccount struct {
	DID         string  `json:"did"`
	Handle      *string `json:"handle,omitempty"`
	DisplayName *string `json:"displayName,omitempty"`
	AvatarURL   *string `json:"avatarUrl,omitempty"`
	Description *string `json:"description,omitempty"`
}

// TalkedAboutAccountCandidate provides story/speaker counts and deterministic tie-break
// evidence for account highlights.
type TalkedAboutAccountCandidate struct {
	Account              TalkedAboutAccount `json:"account"`
	DistinctStoryCount   int                `json:"distinctStoryCount"`
	DistinctSpeakerCount int                `json:"distinctSpeakerCount"`
	BestStoryRank        int                `json:"bestStoryRank"`
	LatestMentionAt      *time.Time         `json:"latestMentionAt,omitempty"`
}

// Edition contains a materialized ranked generation’s lead, spotlight, rail, general,
// trending, and account sections.
type Edition struct {
	AlgorithmVersion    string               `json:"algorithmVersion"`
	GenerationID        string               `json:"generationId"`
	GeneratedAt         time.Time            `json:"generatedAt"`
	Language            string               `json:"language"`
	Cursor              *string              `json:"cursor,omitempty"`
	Source              string               `json:"source"`
	Degraded            bool                 `json:"degraded"`
	LeadStories         []FeedItem           `json:"leadStories"`
	PublicationPanels   []PublicationPanel   `json:"publicationPanels"`
	StoryRails          []StoryRail          `json:"storyRails"`
	GeneralStories      []FeedItem           `json:"generalStories"`
	TrendingStories     []FeedItem           `json:"trendingStories"`
	TalkedAboutAccounts []TalkedAboutAccount `json:"talkedAboutAccounts"`
}

func normalized(value string) string { return strings.ToLower(strings.TrimSpace(value)) }
func hasReason(item FeedItem, reasons ...ReasonCode) bool {
	for _, reasonCode := range item.Reasons {
		for _, wanted := range reasons {
			if reasonCode == wanted {
				return true
			}
		}
	}
	return false
}
func directStandardStory(item FeedItem) bool {
	if item.RepresentativeURI == nil {
		return false
	}
	uri := strings.ToLower(*item.RepresentativeURI)
	return strings.Contains(uri, "/site.standard.document/") || strings.Contains(uri, "/site.standard.entry/")
}
func publicationKey(item FeedItem) string {
	if item.Source.PublicationKey != nil && normalized(*item.Source.PublicationKey) != "" {
		return normalized(*item.Source.PublicationKey)
	}
	if item.Source.Publication != nil && normalized(*item.Source.Publication) != "" {
		return "publication:" + normalized(*item.Source.Publication)
	}
	return "domain:" + normalized(item.Source.Domain)
}

// AssembleEdition allocates deduplicated stories into deterministic edition sections and
// selects qualifying account highlights.
func AssembleEdition(generation string, at time.Time, language string, cursor *string, source string, degraded bool, ranked []FeedItem, accounts []TalkedAboutAccountCandidate) Edition {
	result := Edition{AlgorithmVersion: EditionVersion, GenerationID: generation, GeneratedAt: at, Language: language, Cursor: cursor, Source: source, Degraded: degraded, LeadStories: []FeedItem{}, PublicationPanels: []PublicationPanel{}, StoryRails: []StoryRail{}, GeneralStories: []FeedItem{}, TrendingStories: []FeedItem{}, TalkedAboutAccounts: []TalkedAboutAccount{}}
	seen, domains, allocated := map[string]bool{}, map[string]bool{}, map[string]bool{}
	stories := []FeedItem{}
	for _, story := range ranked {
		if !seen[story.ItemID] {
			seen[story.ItemID] = true
			stories = append(stories, story)
		}
	}
	for _, story := range stories {
		domain := normalized(story.Source.Domain)
		if domains[domain] {
			continue
		}
		domains[domain] = true
		result.LeadStories = append(result.LeadStories, story)
		if len(result.LeadStories) == 4 {
			break
		}
	}
	hasStandard := false
	for _, story := range result.LeadStories {
		hasStandard = hasStandard || directStandardStory(story)
	}
	if len(result.LeadStories) == 4 && !hasStandard {
		for _, story := range stories[:min(10, len(stories))] {
			if !directStandardStory(story) {
				continue
			}
			conflict := false
			for itemIndex, lead := range result.LeadStories {
				if lead.ItemID == story.ItemID || itemIndex < 3 && normalized(lead.Source.Domain) == normalized(story.Source.Domain) {
					conflict = true
				}
			}
			if !conflict {
				result.LeadStories[3] = story
				break
			}
		}
	}
	for _, story := range result.LeadStories {
		allocated[story.ItemID] = true
	}
	groups := map[string][]FeedItem{}
	keys := []string{}
	for _, story := range stories {
		if allocated[story.ItemID] {
			continue
		}
		key := publicationKey(story)
		if groups[key] == nil {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], story)
	}
	for _, key := range keys {
		group := groups[key]
		if len(group) < 2 {
			continue
		}
		selected := group[:min(3, len(group))]
		publicationSource := selected[0].Source
		result.PublicationPanels = append(result.PublicationPanels, PublicationPanel{EditionPublication{key, publicationSource.Publication, publicationSource.Name, publicationSource.Domain, publicationSource.HomepageURL, publicationSource.IconURL}, selected})
		for _, story := range selected {
			allocated[story.ItemID] = true
		}
		if len(result.PublicationPanels) == 6 {
			break
		}
	}
	for _, rail := range []struct {
		id, title string
		reason    ReasonCode
		matches   []ReasonCode
	}{{"breaking-developing", "Breaking & Developing", BreakingStory, []ReasonCode{BreakingStory, WidelyDiscussed}}, {"across-communities", "Across Communities", SharedAcrossCommunities, []ReasonCode{SharedAcrossCommunities}}, {"resurfacing", "Resurfacing", Resurfacing, []ReasonCode{Resurfacing}}} {
		selected := []FeedItem{}
		for _, story := range stories {
			if !allocated[story.ItemID] && hasReason(story, rail.matches...) {
				selected = append(selected, story)
			}
		}
		if len(selected) < 4 {
			continue
		}
		selected = selected[:min(10, len(selected))]
		result.StoryRails = append(result.StoryRails, StoryRail{rail.id, rail.title, rail.reason, selected})
		for _, story := range selected {
			allocated[story.ItemID] = true
		}
	}
	for _, story := range stories {
		if !allocated[story.ItemID] {
			result.GeneralStories = append(result.GeneralStories, story)
		}
		if hasReason(story, BreakingStory, WidelyDiscussed) {
			result.TrendingStories = append(result.TrendingStories, story)
		}
	}
	for _, story := range stories {
		if !hasReason(story, BreakingStory, WidelyDiscussed) {
			result.TrendingStories = append(result.TrendingStories, story)
		}
	}
	result.TrendingStories = result.TrendingStories[:min(10, len(result.TrendingStories))]
	precedes := func(leftAccount, rightAccount TalkedAboutAccountCandidate) bool {
		if leftAccount.DistinctStoryCount != rightAccount.DistinctStoryCount {
			return leftAccount.DistinctStoryCount > rightAccount.DistinctStoryCount
		}
		if leftAccount.DistinctSpeakerCount != rightAccount.DistinctSpeakerCount {
			return leftAccount.DistinctSpeakerCount > rightAccount.DistinctSpeakerCount
		}
		if leftAccount.BestStoryRank != rightAccount.BestStoryRank {
			return leftAccount.BestStoryRank < rightAccount.BestStoryRank
		}
		if leftAccount.LatestMentionAt == nil && rightAccount.LatestMentionAt != nil {
			return false
		}
		if leftAccount.LatestMentionAt != nil && rightAccount.LatestMentionAt == nil {
			return true
		}
		if leftAccount.LatestMentionAt != nil && !leftAccount.LatestMentionAt.Equal(*rightAccount.LatestMentionAt) {
			return leftAccount.LatestMentionAt.After(*rightAccount.LatestMentionAt)
		}
		return normalized(leftAccount.Account.DID) < normalized(rightAccount.Account.DID)
	}
	best := map[string]TalkedAboutAccountCandidate{}
	for _, accountCandidate := range accounts {
		if accountCandidate.DistinctStoryCount < 2 || accountCandidate.DistinctSpeakerCount < 3 {
			continue
		}
		key := normalized(accountCandidate.Account.DID)
		if existingAccount, ok := best[key]; !ok || precedes(accountCandidate, existingAccount) {
			best[key] = accountCandidate
		}
	}
	selected := []TalkedAboutAccountCandidate{}
	for _, accountCandidate := range best {
		selected = append(selected, accountCandidate)
	}
	sort.Slice(selected, func(itemIndex, comparisonIndex int) bool {
		return precedes(selected[itemIndex], selected[comparisonIndex])
	})
	for _, accountCandidate := range selected[:min(10, len(selected))] {
		result.TalkedAboutAccounts = append(result.TalkedAboutAccounts, accountCandidate.Account)
	}
	return result
}
