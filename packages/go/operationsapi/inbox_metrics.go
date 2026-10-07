package operationsapi

type InboxMetrics struct {
	Pending                 int       `json:"pending"`
	Leased                  int       `json:"leased"`
	Retrying                int       `json:"retrying"`
	Applied                 int       `json:"applied"`
	FilteredScope           int       `json:"filteredScope"`
	DeadLetters             int       `json:"deadLetters"`
	Total                   int       `json:"total"`
	OldestPendingAt         *WireTime `json:"oldestPendingAt,omitempty"`
	OldestPendingAgeSeconds *float64  `json:"oldestPendingAgeSeconds,omitempty"`
}
