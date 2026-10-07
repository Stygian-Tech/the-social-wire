package thinappviewcore

// RepositorySnapshot is complete for the requested collections at one signed
// revision. It excludes historical commits, blobs, and unrelated record bodies.
type RepositorySnapshot struct {
	PDSBase   string
	CommitCID string
	Revision  string
	Records   []RepositorySnapshotRecord
}
