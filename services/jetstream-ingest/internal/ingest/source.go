package ingest

import (
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
)

type SourceIdentity struct {
	PipelineMode      string
	Environment       string
	Host              string
	StreamNSID        string
	FilterFingerprint string
	CursorKind        string
	Generation        string
}

func SourceFromConfig(cfg config.Config) SourceIdentity {
	return SourceIdentity{
		PipelineMode:      cfg.PipelineMode,
		Environment:       cfg.Environment,
		Host:              cfg.Host,
		StreamNSID:        cfg.StreamNSID,
		FilterFingerprint: cfg.FilterFingerprint,
		CursorKind:        cfg.CursorKind,
		Generation:        cfg.SourceGeneration,
	}
}

func (s SourceIdentity) IsWire() bool {
	return s.PipelineMode == config.WirePipelineMode
}

func (s SourceIdentity) ValidateCheckpoint(checkpoint Checkpoint) error {
	if checkpoint.Host != s.Host || checkpoint.StreamNSID != s.StreamNSID ||
		checkpoint.FilterFingerprint != s.FilterFingerprint || checkpoint.CursorKind != s.CursorKind {
		return fmt.Errorf("checkpoint identity does not match configured source generation %q", s.Generation)
	}
	return nil
}

type Checkpoint struct {
	Host                   string
	StreamNSID             string
	FilterFingerprint      string
	CursorKind             string
	LastStagedSeq          *uint64
	LastStagedAt           time.Time
	ReplayBytesDownloaded  int64
	ReplayState            string
	ReplayAfterSeq         *uint64
	ReplayBeforeSeq        *uint64
	ReplaySealedSeq        *uint64
	ReplayRetryCount       int
	ReplayRangeResumeCount int
	ReplayETag             string
	ReplayLastProgressAt   time.Time
}
