package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/service"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

const leaseAcquireRetryInterval = time.Second

type leaseAcquirer interface {
	AcquireLease(context.Context, string, string, time.Duration) (store.Lease, error)
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)
	if err := run(logger); err != nil {
		logger.Error("Jetstream V2 ingest stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	state := &health.State{}
	server := &http.Server{
		Addr: ":" + strconv.Itoa(cfg.Port), Handler: state.Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("health server listening", "port", cfg.Port)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrors <- err
		}
	}()
	defer func() {
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownContext)
	}()

	source := ingest.SourceFromConfig(cfg)
	database, err := store.Open(ctx, cfg.DatabaseURL, source)
	if err != nil {
		return err
	}
	defer database.Close()
	if cfg.PipelineMode == config.WirePipelineMode {
		database.ConfigureWireAdmission(cfg.WireInboxMaxRows, cfg.WireDatabaseMaxBytes)
	}
	state.Database(true)
	// Validate an existing generation's immutable source identity before taking
	// its lease or reconciling the multi-million-row Wire admission counter. A
	// stale deployment must fail closed without turning a configuration mismatch
	// into a repeated full-inbox scan.
	if _, err := database.LoadCheckpoint(ctx); err != nil {
		return err
	}

	ownerID, err := newOwnerID()
	if err != nil {
		return err
	}
	lease, err := acquireLeaseWithRetry(
		ctx,
		database,
		cfg.LeaderLeaseName,
		ownerID,
		cfg.LeaderLeaseTTL,
		leaseAcquireRetryInterval,
		logger,
	)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return err
	}
	state.Lease(true)
	logger.Info("acquired fenced ingestion lease", "lease", lease.Name, "fencingToken", lease.FencingToken)
	if cfg.PipelineMode == config.WirePipelineMode {
		if err := database.ReconcileWireAdmission(ctx); err != nil {
			return err
		}
	}

	workerContext, stopWorker := context.WithCancel(ctx)
	leaseErrors := make(chan error, 1)
	leaseDone := make(chan struct{})
	go func() {
		defer close(leaseDone)
		ticker := time.NewTicker(cfg.LeaderLeaseTTL / 3)
		defer ticker.Stop()
		for {
			select {
			case <-workerContext.Done():
				return
			case <-ticker.C:
				renewed, renewErr := database.RenewLease(workerContext, lease, cfg.LeaderLeaseTTL)
				if renewErr != nil {
					state.Lease(false)
					leaseErrors <- renewErr
					stopWorker()
					return
				}
				lease = renewed
			}
		}
	}()

	runnerErrors := make(chan error, 1)
	go func() { runnerErrors <- service.NewRunner(cfg, database, lease, state, logger).Run(workerContext) }()
	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-serverErrors:
	case runErr = <-leaseErrors:
	case runErr = <-runnerErrors:
	}
	stopWorker()
	<-leaseDone
	state.Stream(false)
	state.Lease(false)
	releaseContext, cancelRelease := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRelease()
	if releaseErr := database.ReleaseLease(releaseContext, lease); releaseErr != nil && runErr == nil {
		runErr = releaseErr
	}
	return runErr
}

func acquireLeaseWithRetry(
	ctx context.Context,
	database leaseAcquirer,
	leaseName string,
	ownerID string,
	ttl time.Duration,
	retryInterval time.Duration,
	logger *slog.Logger,
) (store.Lease, error) {
	waitingForHandoff := false
	for {
		lease, err := database.AcquireLease(ctx, leaseName, ownerID, ttl)
		if err == nil {
			return lease, nil
		}
		if !errors.Is(err, store.ErrLeaseUnavailable) {
			return store.Lease{}, err
		}
		if !waitingForHandoff {
			logger.Info("waiting for ingestion lease handoff", "lease", leaseName)
			waitingForHandoff = true
		}

		timer := time.NewTimer(retryInterval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return store.Lease{}, ctx.Err()
		case <-timer.C:
		}
	}
}

func newOwnerID() (string, error) {
	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		return "", fmt.Errorf("generate lease owner ID: %w", err)
	}
	host, _ := os.Hostname()
	return host + "-" + hex.EncodeToString(random), nil
}
