package corpuscore

import "math"

func finiteNonnegative(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value >= 0
}
func finiteConfidence(value float64) bool { return finiteNonnegative(value) && value <= 1 }
func boundedSourceStrings(values []string, maximum, width int) bool {
	if len(values) > maximum {
		return false
	}
	for _, value := range values {
		if len(value) > width {
			return false
		}
	}
	return true
}
func validSportsSourceCandidate(c SportsSourceCandidate) bool {
	if c.ItemID == "" || len(c.ItemID) > 128 || len(c.CanonicalURL) > 16384 || len(c.Title) > 16384 || len(c.Domain) > 2048 || !sportsSourceRevision.MatchString(c.PresentationFingerprint) || !finiteNonnegative(c.BaseScore) || len(c.Analysis.Associations) > 100 || len(c.Analysis.Materiality) > 128 || !boundedSourceStrings(c.Analysis.SportIDs, 100, 128) || !boundedSourceStrings(c.Analysis.CompetitionIDs, 100, 128) {
		return false
	}
	for _, a := range c.Analysis.Associations {
		if !finiteConfidence(a.Confidence) || len(a.EntityID) > 128 || !boundedSourceStrings(a.Evidence, 20, 256) {
			return false
		}
	}
	return true
}
func validFinanceGeneration(g FinanceGeneration) bool {
	if len(g.Candidates) > 5000 || len(g.Instruments) > 50000 {
		return false
	}
	for _, c := range g.Candidates {
		if !finiteNonnegative(c.BaseScore) {
			return false
		}
		for _, a := range c.Analysis.Associations {
			if !finiteConfidence(a.Confidence) {
				return false
			}
		}
	}
	return true
}
