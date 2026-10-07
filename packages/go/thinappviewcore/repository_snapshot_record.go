package thinappviewcore

import "encoding/json"

type RepositorySnapshotRecord struct {
	URI, CID string
	Value    json.RawMessage
}
