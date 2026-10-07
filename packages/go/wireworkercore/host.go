package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

type Host struct {
	DB                             *sql.DB
	Config                         RuntimeConfig
	Processor                      *PostgresInboxProcessor
	labels                         *BaselineLabelRefresher
	topics                         *topicworkercore.Worker
	enrichment                     *EnrichmentHost
	hydration                      *DependencyHydrator
	publicationRecovery            *PublicationSignalRecovery
	drainEvidence, cleanupEvidence *DrainEvidence
	ranking, graph                 *RankingScheduler
	runMu                          sync.Mutex
	active                         atomic.Bool
}

func NewHost(environment map[string]string, role string) (*Host, error) {
	config, err := LoadRuntimeConfig(environment, role)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("pgx", config.DatabaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(config.MaximumConnections)
	db.SetMaxIdleConns(config.MaximumConnections)
	db.SetConnMaxIdleTime(5 * time.Minute)
	host := &Host{DB: db, Config: config, drainEvidence: &DrainEvidence{}, cleanupEvidence: &DrainEvidence{}, ranking: &RankingScheduler{}, graph: &RankingScheduler{}}
	fail := func(err error) (*Host, error) { db.Close(); return nil, err }
	host.topics, err = topicworkercore.NewWorker(db, environment)
	if err != nil {
		return fail(err)
	}
	if config.Cycle.Mode == "off" {
		return host, nil
	}
	hasher, err := wirecore.NewActorHasher([]byte(config.ActorSecret))
	if err != nil {
		return fail(err)
	}
	pds := &thinappviewcore.PDSClient{}
	resolver := NewPublicResolver(db, pds)
	journal := &PostgresRecommendationJournal{DB: db, DependencyVerification: config.DependencyVerification}
	host.Processor = &PostgresInboxProcessor{PostgresInboxClaims: PostgresInboxClaims{DB: db, Scope: config.Scope, BatchSize: config.InboxBatch, Concurrency: config.InboxConcurrency}, Hasher: hasher, Standard: StandardRecordApplication{DB: db, Hasher: hasher, Publications: resolver, Blobs: resolver}, Recommendations: journal, External: PostgresExternalSignalProjector{Hasher: hasher}, DeferredRecommendations: config.DeferredRecommendations}
	if role == "drain" && config.Scope != nil {
		host.publicationRecovery = &PublicationSignalRecovery{DB: db, Hasher: hasher, Scope: *config.Scope}
	}
	if role == "rank" {
		host.labels = &BaselineLabelRefresher{Store: PostgresBaselineLabelStore{DB: db}, Query: HTTPLabelQuery{}, Labelers: config.Labelers, CandidateLimit: config.Cycle.CandidateLimit, MaximumAge: config.LabelMaximumAge}
		host.enrichment, err = NewEnrichmentHost(db, pds, config, environment)
		if err != nil {
			return fail(err)
		}
		if config.DependencyVerification {
			host.hydration = &DependencyHydrator{Store: DependencyRecoveryStore{DB: db, Environment: config.DependencyEnvironment}, Verifier: HTTPPublicRecordVerifier{PDS: pds}, Processor: host.Processor}
		}
	}
	return host, nil
}
func (h *Host) Startup(ctx context.Context) error {
	if h == nil || h.DB == nil {
		return errors.New("Wire host is not configured")
	}
	if err := h.DB.PingContext(ctx); err != nil {
		return err
	}
	if h.Config.Cycle.Mode == "off" {
		return nil
	}
	relations := []string{"wire_ingestion_inbox", "wire_standard_record_fences", "wire_recommendation_journal", "wire_signal_rollup_control", "wire_items", "wire_item_aliases"}
	if h.Config.Role == "rank" {
		relations = append(relations, "wire_rank_generations", "wire_actor_communities", "wire_labels")
	}
	for _, relation := range relations {
		var exists bool
		if err := h.DB.QueryRowContext(ctx, `SELECT to_regclass($1)IS NOT NULL`, relation).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return errors.New("Wire required relation missing: " + relation)
		}
	}
	if h.enrichment != nil {
		return h.enrichment.Startup(ctx)
	}
	return nil
}
func (h *Host) Ready(ctx context.Context) error {
	if err := h.DB.PingContext(ctx); err != nil {
		return err
	}
	if h.Config.Cycle.Mode == "off" {
		return nil
	}
	if !h.active.Load() {
		return errors.New("Wire runtime is not running")
	}
	now := time.Now()
	if h.Config.Role == "drain" {
		return h.drainEvidence.Ready(now)
	}
	if !h.ranking.IsGenerationReady(now, max(h.Config.Interval*2, 600*time.Second)) {
		return errors.New("Wire generation is stale")
	}
	if h.Config.CleanupEnabled {
		if err := h.cleanupEvidence.Ready(now); err != nil {
			return err
		}
	}
	return nil
}

// Run joins every child before returning so coordinator lease cancellation cannot
// leave an old owner fetching or writing after a replacement has started.
func (h *Host) Run(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	h.runMu.Lock()
	defer h.runMu.Unlock()
	if err := h.Startup(ctx); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	h.active.Store(true)
	defer h.active.Store(false)
	var group sync.WaitGroup
	failures := make(chan error, 12)
	start := func(operation func(context.Context) error) {
		group.Go(func() {
			err := operation(ctx)
			if err == nil && ctx.Err() == nil {
				err = errors.New("Wire child exited unexpectedly")
			}
			if err != nil && ctx.Err() == nil {
				failures <- err
				cancel()
			}
		})
	}
	enabled := h.Config.Cycle.Mode != "off"
	if h.Config.Role == "drain" && enabled {
		start(func(ctx context.Context) error {
			return DrainRuntime{Processor: h.Processor, Evidence: h.drainEvidence, Config: h.drainConfig(), OnFailure: wireRuntimeFailure}.Run(ctx)
		})
		start(func(ctx context.Context) error {
			return h.loop(ctx, 15*time.Second, 15*time.Second, func(ctx context.Context, at time.Time) error { return h.topics.ProjectFinance(ctx, at) })
		})
		start(func(ctx context.Context) error {
			return h.loop(ctx, 15*time.Second, 15*time.Second, func(ctx context.Context, at time.Time) error { return h.topics.ProjectSports(ctx, at) })
		})
		if h.publicationRecovery != nil {
			start(func(ctx context.Context) error {
				return h.runPublicationRecovery(ctx)
			})
		}
		if h.Config.DeferredRecommendations {
			start(h.runRecommendationRecovery)
		}
	}
	if h.Config.Role == "rank" {
		if enabled && authority == nil {
			return ErrMissingAuthority
		}
		start(func(ctx context.Context) error { return h.runRanking(ctx, authority) })
		if enabled {
			start(h.runGraph)
			start(func(ctx context.Context) error { return h.enrichment.RunWithAuthority(ctx, authority) })
			start(func(ctx context.Context) error {
				return h.loop(ctx, 15*time.Second, 15*time.Second, func(ctx context.Context, at time.Time) error { return h.topics.RefreshProviders(ctx, authority, at) })
			})
			if h.Config.CleanupEnabled {
				start(h.runCleanup)
			}
			if h.hydration != nil {
				snapshots := *h.Processor
				snapshots.PostgresInboxClaims = PostgresInboxClaims{DB: h.DB, Scope: &InboxScope{Environment: h.Config.DependencyEnvironment, Generations: []string{HydrationGeneration}}, BatchSize: 16, Concurrency: 2}
				start(func(ctx context.Context) error { return h.hydration.Run(ctx, &snapshots) })
			}
		}
	}
	if !enabled && h.Config.Role == "drain" {
		start(func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() })
	}
	<-ctx.Done()
	group.Wait()
	close(failures)
	var result error
	for err := range failures {
		result = errors.Join(result, err)
	}
	if result != nil {
		return result
	}
	return ctx.Err()
}
func wireRuntimeFailure(err error) {
	slog.Error("Wire background operation failed; durable work retained")
}
func (h *Host) loop(ctx context.Context, interval, retry time.Duration, operation func(context.Context, time.Time) error) error {
	for {
		err := operation(ctx, time.Now().UTC())
		if ctx.Err() != nil {
			return ctx.Err()
		}
		delay := interval
		if err != nil {
			wireRuntimeFailure(err)
			delay = retry
		}
		if err = waitContext(ctx, delay); err != nil {
			return err
		}
	}
}
func (h *Host) runRanking(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	store := &PostgresGenerationStore{DB: h.DB, Authority: authority, GlobalCandidateProjectionEnabled: h.Config.GlobalCandidateProjection}
	cycle := Cycle{Store: store, Config: h.Config.Cycle}
	if h.labels != nil {
		cycle.RefreshLabels = h.labels.Refresh
		cycle.MaintainInbox = PostgresSignalRollupStore{DB: h.DB, IncrementalEnabled: h.Config.IncrementalRollups}.Refresh
	}
	for {
		reservation, err := h.ranking.Reserve(time.Now())
		if err != nil {
			return err
		}
		if reservation.Token == "" {
			if err = waitContext(ctx, reservation.Wait); err != nil {
				return err
			}
			continue
		}
		at := time.Now().UTC()
		if h.Config.Cycle.Mode != "off" {
			if err := h.topics.RefreshCatalog(ctx, authority, at); err != nil {
				if ctx.Err() != nil {
					h.ranking.Failed(reservation.Token, time.Now())
					return ctx.Err()
				}
				wireRuntimeFailure(err)
			}
		}
		outcome, err := cycle.Run(ctx, at)
		if ctx.Err() != nil {
			h.ranking.Failed(reservation.Token, time.Now())
			return ctx.Err()
		}
		if err != nil {
			h.ranking.Failed(reservation.Token, time.Now())
			wireRuntimeFailure(err)
		} else {
			h.ranking.Succeeded(reservation.Token, time.Now(), h.Config.Interval)
			if err = materializeCycleTopics(ctx, outcome, func() error { return h.topics.MaterializeFinance(ctx, authority, at) }, func() error { return h.topics.MaterializeSports(ctx, authority, at) }); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				wireRuntimeFailure(err)
			}
		}
	}
}
func (h *Host) runGraph(ctx context.Context) error {
	for {
		reservation, err := h.graph.Reserve(time.Now())
		if err != nil {
			return err
		}
		if reservation.Token == "" {
			if err = waitContext(ctx, reservation.Wait); err != nil {
				return err
			}
			continue
		}
		started := time.Now()
		next, err := (GraphMaintenance{DB: h.DB}).RefreshCommunities(ctx, started.UTC())
		if err != nil || ctx.Err() != nil {
			h.graph.Failed(reservation.Token, time.Now())
			if ctx.Err() != nil {
				return ctx.Err()
			}
			wireRuntimeFailure(err)
		} else {
			delay := min(6*time.Hour, max(time.Second, time.Until(next)))
			h.graph.Succeeded(reservation.Token, time.Now(), time.Since(started)+delay)
		}
	}
}
func (h *Host) runCleanup(ctx context.Context) error {
	backoff := max(time.Millisecond, h.Config.CleanupIdle)
	for {
		at := time.Now().UTC()
		token := h.cleanupEvidence.operationStarted(at)
		count, err := h.Processor.DeleteTerminal(ctx, at, h.Config.CleanupBatch)
		h.cleanupEvidence.operationFinished(token, time.Now(), err)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		delay := h.Config.CleanupIdle
		if err == nil {
			h.cleanupEvidence.admissionFinished(time.Now(), nil)
			backoff = max(time.Millisecond, h.Config.CleanupIdle)
			if count >= h.Config.CleanupBatch {
				delay = 0
			}
		} else {
			wireRuntimeFailure(err)
			delay = backoff
			backoff = min(30*time.Second, backoff*2)
		}
		if err = waitContext(ctx, delay); err != nil {
			return err
		}
	}
}
func (h *Host) runPublicationRecovery(ctx context.Context) error {
	for {
		count, err := h.publicationRecovery.RunBatch(ctx, time.Now().UTC(), 100)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		delay := time.Duration(0)
		if count == 0 || err != nil {
			delay = 5 * time.Second
		}
		if err != nil {
			wireRuntimeFailure(err)
		}
		if err = waitContext(ctx, delay); err != nil {
			return err
		}
	}
}

func (h *Host) drainConfig() DrainConfig {
	config := DefaultDrainConfig()
	config.Concurrency = h.Config.InboxConcurrency
	config.Idle = h.Config.InboxIdle
	return config
}

func (h *Host) runRecommendationRecovery(ctx context.Context) error {
	var lastBacklog time.Time
	scope := h.Config.Scope
	if scope != nil {
		scope = &InboxScope{Environment: scope.Environment}
	}
	journal := h.Processor.Recommendations.(*PostgresRecommendationJournal)
	for {
		at := time.Now().UTC()
		counts, err := journal.Recover(ctx, at, 16, scope)
		if err == nil && (lastBacklog.IsZero() || at.Sub(lastBacklog) >= time.Minute) {
			backlog, queryErr := journal.Backlog(ctx, at, scope)
			if queryErr != nil {
				err = queryErr
			} else {
				slog.Info("Wire deferred recommendation backlog", "pending", backlog.PendingCount, "conflicted", backlog.ConflictCount)
				lastBacklog = at
			}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		delay := 5 * time.Second
		if err != nil {
			wireRuntimeFailure(err)
			delay = 30 * time.Second
		} else if counts.Attempted > 0 {
			slog.Info("Wire recommendation recovery completed", "attempted", counts.Attempted, "resolved", counts.Resolved)
		}
		if err = waitContext(ctx, delay); err != nil {
			return err
		}
	}
}

// SetSchedulers installs process-lifetime reservations before starting this host.
// Coordinator role reacquisition must reuse them to preserve retry and cadence.
func (h *Host) SetSchedulers(ranking, graph *RankingScheduler) {
	h.runMu.Lock()
	defer h.runMu.Unlock()
	if ranking != nil {
		h.ranking = ranking
	}
	if graph != nil {
		h.graph = graph
	}
}

// Finance is derived only after a Wire generation; Sports also refreshes on a
// successful skipped cycle, matching the independently enabled topic runtime.
func materializeCycleTopics(ctx context.Context, outcome CycleOutcome, finance, sports func() error) error {
	var financeErr error
	if outcome.GenerationID != "" {
		financeErr = finance()
	}
	if ctx.Err() != nil {
		return errors.Join(financeErr, ctx.Err())
	}
	return errors.Join(financeErr, sports())
}
