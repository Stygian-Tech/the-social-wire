package operationsapi

import "encoding/json"

type IngestionIncident struct {
	ID                     string                     `json:"id"`
	Environment            string                     `json:"environment"`
	SourceGeneration       *string                    `json:"sourceGeneration,omitempty"`
	SourceHost             *string                    `json:"sourceHost,omitempty"`
	Source                 string                     `json:"source"`
	CursorKind             string                     `json:"cursorKind"`
	StartCursor            *int64                     `json:"startCursor,omitempty"`
	EndCursor              *int64                     `json:"endCursor,omitempty"`
	Category               string                     `json:"category"`
	Status                 string                     `json:"status"`
	OccurrenceCount        int64                      `json:"occurrenceCount"`
	FirstDetectedAt        WireTime                   `json:"firstDetectedAt"`
	LastDetectedAt         WireTime                   `json:"lastDetectedAt"`
	LastError              *string                    `json:"lastError,omitempty"`
	ReplayState            *string                    `json:"replayState,omitempty"`
	ReplayBytesDownloaded  int64                      `json:"replayBytesDownloaded"`
	ReplayRetryCount       int                        `json:"replayRetryCount"`
	ReplayRangeResumeCount int                        `json:"replayRangeResumeCount"`
	ReplaySealedSequence   *int64                     `json:"replaySealedSequence,omitempty"`
	RecoveredThroughCursor *int64                     `json:"recoveredThroughCursor,omitempty"`
	VerificationEvidence   map[string]json.RawMessage `json:"verificationEvidence"`
	ResolvedAt             *WireTime                  `json:"resolvedAt,omitempty"`
	UpdatedAt              WireTime                   `json:"updatedAt"`
	Version                int                        `json:"version"`
}
