package operationsapi

type ViewerCounts struct {
	KnownViewers     int      `json:"knownViewers"`
	ActiveViewers7d  int      `json:"activeViewers7d"`
	ActiveViewers30d int      `json:"activeViewers30d"`
	ObservedAt       WireTime `json:"observedAt"`
}
