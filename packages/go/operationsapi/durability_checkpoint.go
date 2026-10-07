package operationsapi

type DurabilityCheckpoint struct {
	Environment                      string    `json:"environment"`
	SourceGeneration                 string    `json:"sourceGeneration"`
	SourceHost                       string    `json:"sourceHost"`
	StreamNSID                       string    `json:"streamNSID"`
	FilterFingerprint                string    `json:"filterFingerprint"`
	CursorKind                       string    `json:"cursorKind"`
	LastStagedSequence               *int64    `json:"lastStagedSequence,omitempty"`
	LastStagedEventAt                *WireTime `json:"lastStagedEventAt,omitempty"`
	LastStagedAt                     *WireTime `json:"lastStagedAt,omitempty"`
	LastAppliedSequence              *int64    `json:"lastAppliedSequence,omitempty"`
	LastAppliedEventAt               *WireTime `json:"lastAppliedEventAt,omitempty"`
	LastAppliedAt                    *WireTime `json:"lastAppliedAt,omitempty"`
	LastReconciledRepositoryRevision *string   `json:"lastReconciledRepositoryRevision,omitempty"`
	LastReconciledAt                 *WireTime `json:"lastReconciledAt,omitempty"`
	ReplayState                      string    `json:"replayState"`
	ReplayAfterSequence              *int64    `json:"replayAfterSequence,omitempty"`
	ReplayBeforeSequence             *int64    `json:"replayBeforeSequence,omitempty"`
	ReplaySealedSequence             *int64    `json:"replaySealedSequence,omitempty"`
	ReplayBytesDownloaded            int64     `json:"replayBytesDownloaded"`
	ReplayRetryCount                 int       `json:"replayRetryCount"`
	ReplayRangeResumeCount           int       `json:"replayRangeResumeCount"`
	ReplayLastProgressAt             *WireTime `json:"replayLastProgressAt,omitempty"`
	IntakeHeartbeatAt                *WireTime `json:"intakeHeartbeatAt,omitempty"`
	UpdatedAt                        WireTime  `json:"updatedAt"`
}
