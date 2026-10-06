package wirecore

type DiversityPolicy struct {
	FirstPageLimit    int `json:"firstPageLimit"`
	MaxPerDomain      int `json:"maxPerDomain"`
	MaxPerPublication int `json:"maxPerPublication"`
	MaxPerAuthor      int `json:"maxPerAuthor"`
	MaxPerTopic       int `json:"maxPerTopic"`
	MaxPerCommunity   int `json:"maxPerCommunity"`
	MinimumStrictFill int `json:"minimumStrictFill"`
}

func DefaultDiversityPolicy() DiversityPolicy { return DiversityPolicy{50, 4, 3, 2, 5, 10, 40} }
func (p DiversityPolicy) allCaps() []int {
	return []int{p.FirstPageLimit, p.MaxPerDomain, p.MaxPerPublication, p.MaxPerAuthor, p.MaxPerTopic, p.MaxPerCommunity, p.MinimumStrictFill}
}

type DiversityIntervention struct {
	CanonicalKey string `json:"canonicalKey"`
	Kind         string `json:"kind"`
}
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
		c := item.Candidate
		violation := ""
		switch {
		case domains[c.SourceDomain] >= caps.domain:
			violation = "domain"
		case c.PublicationID != nil && publications[*c.PublicationID] >= caps.publication:
			violation = "publication"
		case c.AuthorKey != nil && authors[*c.AuthorKey] >= caps.author:
			violation = "author"
		default:
			for _, t := range c.TopicKeys {
				if topics[t] >= caps.topic {
					violation = "topic"
					break
				}
			}
			if violation == "" && c.PrimaryCommunityKey != nil && communities[*c.PrimaryCommunityKey] >= caps.community {
				violation = "community"
			}
		}
		if violation != "" {
			deferred = append(deferred, item)
			interventions = append(interventions, DiversityIntervention{c.CanonicalKey, violation})
			continue
		}
		selected = append(selected, item)
		domains[c.SourceDomain]++
		if c.PublicationID != nil {
			publications[*c.PublicationID]++
		}
		if c.AuthorKey != nil {
			authors[*c.AuthorKey]++
		}
		seen := map[string]bool{}
		for _, t := range c.TopicKeys {
			if !seen[t] {
				topics[t]++
				seen[t] = true
			}
		}
		if c.PrimaryCommunityKey != nil {
			communities[*c.PrimaryCommunityKey]++
		}
	}
	return
}
func Rerank(items []ScoredCandidate, policy DiversityPolicy) DiversityResult {
	if len(items) == 0 {
		return DiversityResult{[]ScoredCandidate{}, []DiversityIntervention{}}
	}
	size := min(policy.FirstPageLimit, len(items))
	caps := diversityCaps{policy.MaxPerDomain, policy.MaxPerPublication, policy.MaxPerAuthor, policy.MaxPerTopic, policy.MaxPerCommunity}
	selected, deferred, interventions := selectDiverse(items, size, caps)
	target := min(size, policy.MinimumStrictFill)
	for i := 0; len(selected) < target && len(deferred) > 0; i++ {
		switch i % 5 {
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
	for _, i := range selected {
		keys[i.Candidate.CanonicalKey] = true
	}
	for _, i := range items {
		if !keys[i.Candidate.CanonicalKey] {
			selected = append(selected, i)
		}
	}
	return DiversityResult{selected, interventions}
}
