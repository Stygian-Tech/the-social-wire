package thinappviewcore

import "time"

// RepositorySnapshotReader retrieves an authoritative tree when listRecords
// cannot advance. Every limit applies to the entire attempt, including retries.
type RepositorySnapshotReader struct {
	PDS                                                                        *PDSClient
	MaximumBytes, MaximumBlocks, MaximumRecords, MaximumRequests, MaximumDepth int
	Timeout                                                                    time.Duration
	Now                                                                        func() time.Time
}
