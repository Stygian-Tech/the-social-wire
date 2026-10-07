package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type PDSResolver interface {
	ResolvePDS(context.Context, string) (string, error)
}
type PublicRepoReader interface {
	ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error)
}
