package appviewworkercore

import (
	"context"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type RepositorySnapshotSource interface {
	Read(context.Context, string, []string) (thinappviewcore.RepositorySnapshot, error)
}
