package corpuscore

import "time"

// MaximumWireGenerationAge bounds last-good serving from the original ranking
// time, including the generation's normal lifetime. Reading never renews it.
const MaximumWireGenerationAge = 6 * time.Hour

func (g generation) servingDeadline() time.Time {
	return g.generated.Add(MaximumWireGenerationAge)
}
