package corpuscore

import (
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// MaximumWireGenerationAge bounds last-good serving from the original ranking
// time, including the generation's normal lifetime. Reading never renews it.
const MaximumWireGenerationAge = wirecore.MaximumWireGenerationAge

func (g generation) servingDeadline() time.Time {
	return g.generated.Add(MaximumWireGenerationAge)
}
