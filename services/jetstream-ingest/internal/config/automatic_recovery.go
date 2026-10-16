package config

// These commit projections have durable source-record mutation fences. Account
// transitions are independently monotonic and share the publication account lock.
// Other pipelines must remain sequential until equivalent ordering is proven.
func (c Config) SupportsAutomaticRecovery() bool {
	if c.PipelineMode != WirePipelineMode || len(c.Collections) == 0 {
		return false
	}
	for _, collection := range c.Collections {
		switch collection {
		case "site.standard.document", "site.standard.entry", "site.standard.publication":
		default:
			return false
		}
	}
	return true
}
