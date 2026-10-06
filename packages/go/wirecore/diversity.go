package wirecore

// Reranks an already scored stream using domain, publication, author, topic, and community
// caps. It progressively relaxes caps to meet minimum fill, completes the first page from
// deferred items, then appends the unselected tail without discarding ranked candidates.

// DiversityPolicy sets first-page caps and the minimum fill that triggers ordered cap
// relaxation.
type DiversityPolicy struct {
	FirstPageLimit    int `json:"firstPageLimit"`
	MaxPerDomain      int `json:"maxPerDomain"`
	MaxPerPublication int `json:"maxPerPublication"`
	MaxPerAuthor      int `json:"maxPerAuthor"`
	MaxPerTopic       int `json:"maxPerTopic"`
	MaxPerCommunity   int `json:"maxPerCommunity"`
	MinimumStrictFill int `json:"minimumStrictFill"`
}

// DefaultDiversityPolicy sets the Swift-compatible
// domain/publication/author/topic/community caps for fifty items.
func DefaultDiversityPolicy() DiversityPolicy { return DiversityPolicy{50, 4, 3, 2, 5, 10, 40} }
func (policy DiversityPolicy) allCaps() []int {
	return []int{policy.FirstPageLimit, policy.MaxPerDomain, policy.MaxPerPublication, policy.MaxPerAuthor, policy.MaxPerTopic, policy.MaxPerCommunity, policy.MinimumStrictFill}
}

// DiversityIntervention identifies a deferred candidate’s cap or a global relaxation step.
type DiversityIntervention struct {
	CanonicalKey string `json:"canonicalKey"`
	Kind         string `json:"kind"`
}

// DiversityResult returns the reranked stream with cap/relaxation evidence.
type DiversityResult struct {
	Items         []ScoredCandidate       `json:"items"`
	Interventions []DiversityIntervention `json:"interventions"`
}
type diversityCaps struct{ domain, publication, author, topic, community int }

func selectDiverse(items []ScoredCandidate, size int, caps diversityCaps) (selected, deferred []ScoredCandidate, interventions []DiversityIntervention) {
	selected = []ScoredCandidate{}
	deferred = []ScoredCandidate{}
	interventions = []DiversityIntervention{}
	domains, publications, authors, topics, communities := map[string]int{}, map[string]int{}, map[string]int{}, map[string]int{}, map[string]int{}
	for _, item := range items {
		if len(selected) >= size {
			break
		}
		candidate := item.Candidate
		violation := ""
		switch {
		case domains[candidate.SourceDomain] >= caps.domain:
			violation = "domain"
		case candidate.PublicationID != nil && publications[*candidate.PublicationID] >= caps.publication:
			violation = "publication"
		case candidate.AuthorKey != nil && authors[*candidate.AuthorKey] >= caps.author:
			violation = "author"
		default:
			for _, topic := range candidate.TopicKeys {
				if topics[topic] >= caps.topic {
					violation = "topic"
					break
				}
			}
			if violation == "" && candidate.PrimaryCommunityKey != nil && communities[*candidate.PrimaryCommunityKey] >= caps.community {
				violation = "community"
			}
		}
		if violation != "" {
			deferred = append(deferred, item)
			interventions = append(interventions, DiversityIntervention{candidate.CanonicalKey, violation})
			continue
		}
		selected = append(selected, item)
		domains[candidate.SourceDomain]++
		if candidate.PublicationID != nil {
			publications[*candidate.PublicationID]++
		}
		if candidate.AuthorKey != nil {
			authors[*candidate.AuthorKey]++
		}
		seen := map[string]bool{}
		for _, topic := range candidate.TopicKeys {
			if !seen[topic] {
				topics[topic]++
				seen[topic] = true
			}
		}
		if candidate.PrimaryCommunityKey != nil {
			communities[*candidate.PrimaryCommunityKey]++
		}
	}
	return
}

// Rerank diversifies the first page, relaxing only as needed, then appends the remaining
// ranked stream.
func Rerank(items []ScoredCandidate, policy DiversityPolicy) DiversityResult {
	if len(items) == 0 {
		return DiversityResult{[]ScoredCandidate{}, []DiversityIntervention{}}
	}
	size := min(policy.FirstPageLimit, len(items))
	caps := diversityCaps{policy.MaxPerDomain, policy.MaxPerPublication, policy.MaxPerAuthor, policy.MaxPerTopic, policy.MaxPerCommunity}
	selected, deferred, interventions := selectDiverse(items, size, caps)
	target := min(size, policy.MinimumStrictFill)
	for itemIndex := 0; len(selected) < target && len(deferred) > 0; itemIndex++ {
		switch itemIndex % 5 {
		case 0:
			caps.topic++
		case 1:
			caps.community++
		case 2:
			caps.author++
		case 3:
			caps.publication++
		case 4:
			caps.domain++
		}
		interventions = append(interventions, DiversityIntervention{"*", "relaxation"})
		selected, deferred, _ = selectDiverse(items, size, caps)
	}
	if len(selected) < size {
		selected = append(selected, deferred[:min(size-len(selected), len(deferred))]...)
	}
	keys := map[string]bool{}
	for _, scoredCandidate := range selected {
		keys[scoredCandidate.Candidate.CanonicalKey] = true
	}
	for _, scoredCandidate := range items {
		if !keys[scoredCandidate.Candidate.CanonicalKey] {
			selected = append(selected, scoredCandidate)
		}
	}
	return DiversityResult{selected, interventions}
}
