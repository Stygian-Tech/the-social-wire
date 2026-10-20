// Package socialdraftcore stores private cross-device draft attachments outside PDS.
package socialdraftcore

import "errors"

var (
	ErrUnavailable   = errors.New("private draft storage unavailable")
	ErrInvalid       = errors.New("invalid private draft input")
	ErrNotFound      = errors.New("private draft not found")
	ErrConflict      = errors.New("private draft revision conflict")
	ErrQuota         = errors.New("private draft quota exceeded")
	ErrUploadPending = errors.New("private draft upload pending")
)

const MaxFileBytes int64 = 100 << 20
const MaxAccountBytes int64 = 1 << 30

type Config struct {
	Endpoint, Bucket, AccessKeyID, SecretAccessKey, Region, StorageKey string
	Enabled                                                            bool
}
type ReserveInput struct {
	AssetID     string `json:"assetId"`
	Name        string `json:"name"`
	ContentType string `json:"contentType"`
	ByteLength  int64  `json:"byteLength"`
	SHA256      string `json:"sha256"`
	Kind        string `json:"kind"`
}
type Asset struct {
	AssetID     string `json:"assetId"`
	Name        string `json:"name"`
	ContentType string `json:"contentType"`
	SHA256      string `json:"sha256"`
	Kind        string `json:"kind"`
	State       string `json:"state"`
	ByteLength  int64  `json:"byteLength"`
}
type ManifestRef struct {
	AssetID string `json:"assetId"`
	Role    string `json:"role"`
	Ref     string `json:"ref"`
}
type AssetBinding struct {
	AssetID string `json:"assetId"`
	Role    string `json:"role"`
	Ref     string `json:"ref"`
	Asset   Asset  `json:"asset"`
}
type Manifest struct {
	DraftID     string         `json:"draftId"`
	Revision    int64          `json:"revision"`
	Deleted     bool           `json:"deleted"`
	Attachments []AssetBinding `json:"attachments"`
}
type PutManifestInput struct {
	DraftID          string        `json:"draftId"`
	ExpectedRevision int64         `json:"expectedRevision"`
	Attachments      []ManifestRef `json:"attachments"`
}
