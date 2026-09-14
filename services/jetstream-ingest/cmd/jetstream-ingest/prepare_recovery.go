package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os/signal"
	"syscall"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

func runArguments(args []string, logger *slog.Logger) error {
	flags := flag.NewFlagSet("jetstream-ingest", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	prepare := flags.Bool("prepare-wire-recovery", false, "initialize a restored Wire source without starting provider streams")
	laneName := flags.String("lane", "", "exact enabled Wire lane to prepare")
	if err := flags.Parse(args); err != nil {
		return errors.New("invalid ingestion command options")
	}
	if flags.NArg() != 0 || (!*prepare && *laneName != "") {
		return errors.New("unexpected ingestion command arguments")
	}
	if !*prepare {
		return run(logger)
	}
	if *laneName == "" {
		return errors.New("--prepare-wire-recovery requires --lane")
	}
	lane, err := config.LoadWireRecovery(*laneName)
	if err != nil {
		return fmt.Errorf("load recovery lane: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	return prepareWireRecovery(ctx, lane, logger)
}

// Deliberately has no Runner, SDK, HTTP client, or health server. It uses the
// same fenced recovery transaction as normal startup, then releases ownership.
func prepareWireRecovery(ctx context.Context, lane config.Lane, logger *slog.Logger) (runErr error) {
	cfg := lane.Config
	if cfg.PipelineMode != config.WirePipelineMode {
		return errors.New("recovery preparation requires Wire mode")
	}
	source := ingest.SourceFromConfig(cfg)
	database, err := store.Open(ctx, cfg.DatabaseURL, source)
	if err != nil {
		return err
	}
	defer database.Close()
	checkpoint, err := database.LoadCheckpoint(ctx)
	if err != nil {
		return err
	}
	if checkpoint == nil {
		return errors.New("recovery preparation requires an existing matching source checkpoint")
	}
	database.ConfigureWireAdmission(cfg.WireInboxMaxRows, cfg.WireDatabaseMaxBytes)
	owner, err := newOwnerID()
	if err != nil {
		return err
	}
	// Acquisition is intentionally single-attempt: never wait out or interrupt a
	// live owner's lease to prepare a recovery job.
	lease, err := database.AcquireLease(ctx, cfg.LeaderLeaseName, owner, cfg.LeaderLeaseTTL)
	if err != nil {
		return err
	}
	defer func() {
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := database.ReleaseLease(releaseCtx, lease); err != nil && runErr == nil {
			runErr = err
		}
	}()
	recovered, err := database.ReconcileWireAdmission(ctx, lease)
	if err != nil {
		return err
	}
	logger.Info("Wire recovery preparation completed without starting provider streams", "lane", lane.Name, "recoveryRequired", recovered)
	return nil
}
