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
	controllerConfig, err := config.LoadController()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if controllerConfig.LegacySingleLane {
		return runSingleLane(ctx, controllerConfig.Lanes[0], controllerConfig.Port, logger)
	}
	return runController(ctx, controllerConfig, logger)
}

func runSingleLane(ctx context.Context, lane config.Lane, port int, logger *slog.Logger) error {
	state := &health.State{}
	server, serverErrors := startHealthServer(port, state.Handler(), logger)
	defer shutdownHealthServer(server)

	laneContext, stopLane := context.WithCancel(ctx)
	defer stopLane()
	laneErrors := make(chan error, 1)
	go func() { laneErrors <- runLane(laneContext, lane, state, logger) }()
	select {
	case <-ctx.Done():
		stopLane()
		<-laneErrors
		return nil
	case err := <-serverErrors:
		stopLane()
		<-laneErrors
		return err
	case err := <-laneErrors:
		return err
	}
}

func runController(ctx context.Context, cfg config.ControllerConfig, logger *slog.Logger) error {
	states := make(map[string]*health.State, len(cfg.Lanes))
	lanes := make([]service.SupervisedLane, 0, len(cfg.Lanes))
	for _, configuredLane := range cfg.Lanes {
		lane := configuredLane
		state := &health.State{}
		states[string(lane.Name)] = state
		lanes = append(lanes, service.SupervisedLane{
			Name: string(lane.Name),
			Run: func(laneContext context.Context) error {
				return runLane(laneContext, lane, state, logger)
			},
		})
	}

	controller := health.NewController(states)
	server, serverErrors := startHealthServer(cfg.Port, controller.Handler(), logger)
	defer shutdownHealthServer(server)

	supervisorContext, stopSupervisor := context.WithCancel(ctx)
	defer stopSupervisor()
	supervisorDone := make(chan struct{})
	go func() {
		service.Supervisor{Lanes: lanes, Logger: logger}.Run(supervisorContext)
		close(supervisorDone)
	}()

	select {
	case <-ctx.Done():
		stopSupervisor()
		<-supervisorDone
		return nil
	case err := <-serverErrors:
		stopSupervisor()
		<-supervisorDone
		return err
	}
}

func startHealthServer(
	port int,
	handler http.Handler,
	logger *slog.Logger,
) (*http.Server, <-chan error) {
	server := &http.Server{
		Addr: ":" + strconv.Itoa(port), Handler: handler,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("health server listening", "port", port)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrors <- err
		}
	}()
	return server, serverErrors
}

func shutdownHealthServer(server *http.Server) {
	shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownContext)
}

func runLane(
	ctx context.Context,
	lane config.Lane,
	state *health.State,
	logger *slog.Logger,
) (runErr error) {
	cfg := lane.Config
	laneLogger := logger.With("lane", lane.Name, "pipelineMode", cfg.PipelineMode)
	state.Reset()
	defer func() {
		state.Database(false)
		state.Lease(false)
		state.Stream(false)
		if runErr != nil && !errors.Is(runErr, context.Canceled) {
			state.Error(runErr)
		}
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
		laneLogger,
	)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil
		}
		return err
	}
	state.Lease(true)
	laneLogger.Info("acquired fenced ingestion lease", "lease", lease.Name, "fencingToken", lease.FencingToken)
	leaseReleased := false
	defer func() {
		if leaseReleased {
			return
		}
		releaseContext, cancelRelease := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelRelease()
		if releaseErr := database.ReleaseLease(releaseContext, lease); releaseErr != nil && runErr == nil {
			runErr = releaseErr
		}
	}()
	if cfg.PipelineMode == config.WirePipelineMode {
		recovered, reconcileErr := database.ReconcileWireAdmission(ctx, lease)
		if reconcileErr != nil {
			return reconcileErr
		}
		if recovered {
			laneLogger.Warn(
				"replaying Wire source after PostgreSQL truncated the UNLOGGED inbox",
				"sourceGeneration", source.Generation,
			)
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
				// Renewal changes only the expiry timestamp. Keep the immutable
				// lease identity local to this goroutine so shutdown can release
				// the original fenced lease without racing this assignment.
				_, renewErr := database.RenewLease(workerContext, lease, cfg.LeaderLeaseTTL)
				if renewErr != nil {
					state.Lease(false)
					leaseErrors <- renewErr
					stopWorker()
					return
				}
			}
		}
	}()

	runnerErrors := make(chan error, 1)
	go func() { runnerErrors <- service.NewRunner(cfg, database, lease, state, laneLogger).Run(workerContext) }()
	select {
	case <-ctx.Done():
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
	leaseReleased = true
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
