package socialdrafts

import (
	"context"
	"io"

	"github.com/stygian-tech/the-social-wire/packages/go/socialdraftcore"
)

// Service keeps HTTP ownership checks separate from private storage operations.
type Service interface {
	Reserve(context.Context, string, socialdraftcore.ReserveInput) (socialdraftcore.Asset, error)
	Upload(context.Context, string, string, io.Reader, int64) (socialdraftcore.Asset, error)
	Download(context.Context, string, string) (io.ReadCloser, socialdraftcore.Asset, error)
	Manifest(context.Context, string, string) (socialdraftcore.Manifest, error)
	PutManifest(context.Context, string, socialdraftcore.PutManifestInput) (socialdraftcore.Manifest, error)
	DeleteManifest(context.Context, string, string, int64) (socialdraftcore.Manifest, error)
}
