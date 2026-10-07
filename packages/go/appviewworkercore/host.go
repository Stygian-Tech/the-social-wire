package appviewworkercore

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"math/rand/v2"
	"strings"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type Host struct {
	Config             HostConfig
	DB                 *sql.DB
	Projector          *EventProjectorRuntime
	RSS                *thinappviewcore.RSSIngestion
	Cache              *thinappviewcore.ProjectionCache
	Redis              *redis.Client
	Telemetry          *TelemetryBuffer
	EvictIdleReadState func(context.Context, time.Time, time.Time, int) (string, int, bool, error)
	OperationsRecovery func(context.Context, *operationscore.RoleLeaseAuthority) error
	Heartbeat          func(context.Context, *operationscore.RoleLeaseAuthority) error
	Readiness          func(context.Context) error
	mu                 sync.RWMutex
	running            bool
	lastProgress       time.Time
}

func NewHost(environment map[string]string, role string) (*Host, error) {
	config, err := hostConfiguration(environment, role)
	if err != nil {
		return nil, err
	}
	dsn := environment["DATABASE_URL"]
	if dsn == "" {
		return nil, errors.New("DATABASE_URL is required")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(max(2, hostInt(environment, "POSTGRES_MAX_CONNECTIONS", 2)))
	db.SetMaxIdleConns(2)
	db.SetConnMaxIdleTime(30 * time.Second)
	cache := &thinappviewcore.ProjectionCache{DB: db, Namespace: socialwireredis.NewKeyNamespace(config.Environment, ""), FirstPageFresh: hostSeconds(environment, "APPVIEW_FIRST_PAGE_CACHE_FRESH_SECONDS", 300), FirstPageHard: hostSeconds(environment, "APPVIEW_FIRST_PAGE_CACHE_HARD_SECONDS", 1800)}
	var redisClient *redis.Client
	backend := environment["APPVIEW_CACHE_BACKEND"]
	if backend == "redis" {
		options, err := redis.ParseURL(environment["REDIS_URL"])
		if err != nil {
			db.Close()
			return nil, err
		}
		options.DialTimeout = 2 * time.Second
		options.ReadTimeout = 2 * time.Second
		options.WriteTimeout = 2 * time.Second
		options.MaxRetries = 0
		if cache.FirstPageHard < cache.FirstPageFresh {
			db.Close()
			return nil, errors.New("Redis first page hard TTL must cover freshness")
		}
		redisClient = redis.NewClient(options)
		cache.Redis = redisClient
	} else if backend != "" && backend != "postgres" {
		db.Close()
		return nil, errors.New("unsupported AppView projection cache backend")
	}
	pds := &thinappviewcore.PDSClient{PLCBase: environment["ATPROTO_PLC_URL"]}
	rss := &thinappviewcore.RSSIngestion{DB: db, Cache: cache, MaximumItems: config.MaximumRSSItems, Retention: config.ContentRetention}
	projector := &EventProjectorRuntime{DB: db, PDS: pds, Cache: cache, RSS: rss, Counters: thinappviewcore.CounterStore{DB: db}, Retention: config.ContentRetention, AppliedRetention: config.AppliedRetention, WorkerID: config.InstanceID}
	restorer := RepositoryRestorer{DB: db, PDS: pds, Projector: projector, RecordBudget: min(200, config.RecoveryRecordBudget), MaximumRateLimitRetries: 3}
	projector.RestoreRepository = restorer.Restore
	host := &Host{Config: config, DB: db, Projector: projector, RSS: rss, Cache: cache, Redis: redisClient}
	readState := &pdsreadstatecore.Store{DB: db, FetchRecord: pds.FetchRecord}
	projector.ReconcileReadState = readState.Reconcile
	projector.Counters.PDSAuthority = readState.PDSAuthority
	projector.Counters.PDSIsRead = readState.IsRead
	host.EvictIdleReadState = readState.EvictIdle
	relayURL := "wss://jetstream1.us-east.bsky.network/subscribe?wantedCollections=site.standard.document&wantedCollections=com.standard.document&wantedCollections=site.standard.entry&wantedCollections=com.standard.entry&wantedCollections=app.thesocialwire.entryReadState&wantedCollections=app.thesocialwire.finance.selection&wantedCollections=app.thesocialwire.sports.selection&wantedCollections=app.thesocialwire.readState&wantedCollections=app.skyreader.feed.subscription&wantedCollections=site.standard.graph.subscription"
	for _, candidate := range strings.Split(environment["THIN_APPVIEW_RELAY_WS_URLS"], ",") {
		if candidate = strings.TrimSpace(candidate); candidate != "" {
			relayURL = candidate
			break
		}
	}
	if strings.TrimSpace(environment["THIN_APPVIEW_RELAY_WS_URLS"]) == "" && strings.TrimSpace(environment["THIN_APPVIEW_RELAY_WS_URL"]) != "" {
		relayURL = strings.TrimSpace(environment["THIN_APPVIEW_RELAY_WS_URL"])
	}
	host.OperationsRecovery = func(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
		if authority == nil {
			return errors.New("Operations recovery role authority unavailable")
		}
		engine := RecoveryEngine{Store: BackfillStore{DB: db, Authority: *authority, Environment: config.Environment, WorkerID: config.InstanceID}, PDS: pds, Projector: projector, RelayURL: relayURL, MaximumAuthors: hostInt(environment, "THIN_APPVIEW_MAX_ENROLL_AUTHORS", 500), RecordCapPerAuthor: config.RecoveryRecordBudget}
		return engine.Run(ctx)
	}
	if config.TelemetryEnabled {
		host.Telemetry = &TelemetryBuffer{Export: host.exportTelemetry}
		service := "projection-pool-appview"
		if role == "coordinator" {
			service = "coordinator-appview"
		}
		if redisClient != nil {
			redisClient.AddHook(RedisTelemetryHook{Buffer: host.Telemetry, Service: service})
		}
		cache.LockTelemetry = func(operation, outcome string) {
			host.Telemetry.Enqueue(MetricSample{Name: "socialwire.appview.cache.locks_total", Value: 1, Dimensions: map[string]string{"service": service, "operation": operation, "outcome": outcome}, At: time.Now()})
		}
	}
	host.Heartbeat = host.runHeartbeat
	host.Readiness = host.checkReadiness
	return host, nil
}
func (h *Host) Close() error {
	if h.Redis != nil {
		_ = h.Redis.Close()
	}
	return h.DB.Close()
}
func (h *Host) Startup(ctx context.Context) error { return h.DB.PingContext(ctx) }
func (h *Host) Ready(ctx context.Context) error {
	if err := h.Startup(ctx); err != nil {
		return err
	}
	h.mu.RLock()
	running := h.running
	last := h.lastProgress
	h.mu.RUnlock()
	if !running || time.Since(last) > 15*time.Second {
		return errors.New("AppView worker heartbeat unavailable")
	}
	if h.Readiness == nil {
		return errors.New("AppView ingestion readiness evidence unavailable")
	}
	return h.Readiness(ctx)
}
func (h *Host) progress() { h.mu.Lock(); h.lastProgress = time.Now(); h.mu.Unlock() }
func (h *Host) Run(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	if h.Projector.ReconcileReadState == nil || h.Projector.Counters.PDSAuthority == nil || h.Projector.Counters.PDSIsRead == nil {
		return errors.New("authoritative PDS read-state adapters are required")
	}
	if h.Heartbeat == nil || h.Readiness == nil {
		return errors.New("AppView operations heartbeat/readiness adapters are required")
	}
	if h.Config.Role == "coordinator" {
		if authority == nil {
			return errors.New("coordinator role authority is required")
		}
		if h.Config.RecoveryEnabled && h.OperationsRecovery == nil {
			return errors.New("Operations recovery adapter is required")
		}
		if h.Config.PDSIdleEviction && h.EvictIdleReadState == nil {
			return errors.New("PDS idle-eviction adapter is required")
		}
	}
	if err := h.Startup(ctx); err != nil {
		return err
	}
	h.mu.Lock()
	h.running = true
	h.lastProgress = time.Now()
	h.mu.Unlock()
	defer func() { h.mu.Lock(); h.running = false; h.mu.Unlock() }()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	errorsChannel := make(chan error, 8)
	var wait sync.WaitGroup
	launch := func(run func(context.Context) error) {
		wait.Add(1)
		go func() {
			defer wait.Done()
			err := run(ctx)
			if err == nil && ctx.Err() == nil {
				err = errors.New("AppView lane ended unexpectedly")
			}
			select {
			case errorsChannel <- err:
			case <-ctx.Done():
			}
		}()
	}
	if h.Config.TelemetryEnabled {
		if h.Telemetry == nil {
			return errors.New("telemetry exporter adapter is required")
		}
		launch(h.Telemetry.Run)
	}
	launch(func(c context.Context) error { return h.Heartbeat(c, authority) })
	launch(func(c context.Context) error {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-c.Done():
				return c.Err()
			case <-ticker.C:
				h.progress()
			}
		}
	})
	if h.Config.Role == "projection" {
		launch(h.runInbox)
		launch(h.runReconciliations)
	} else {
		if h.Config.ProactiveBackfillSuppressed() {
			slog.Info("Suppressing legacy proactive AppView backfill under durable Jetstream V2 authority")
		}
		launch(h.runRetention)
		if h.Config.RSSPoll {
			launch(h.runRSS)
		}
		if h.Config.RecoveryEnabled {
			launch(func(c context.Context) error { return h.OperationsRecovery(c, authority) })
		}
	}
	var err error
	select {
	case <-ctx.Done():
		err = ctx.Err()
	case err = <-errorsChannel:
	}
	cancel()
	wait.Wait()
	return err
}
func workerPause(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (h *Host) runInbox(ctx context.Context) error {
	store := thinappviewcore.InboxStore{DB: h.DB}
	config := h.Config
	processor := InboxProcessor{Telemetry: h.Telemetry, Repository: store, Projector: h.Projector, WorkerID: config.InstanceID, LeaseDuration: config.LeaseDuration, ProjectionTimeout: config.RestoreTimeout, AppliedRetention: config.AppliedRetention, DeadLetterRetention: config.DeadLetterRetention}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		at := time.Now()
		filtered, err := store.FilterOutsideScope(ctx, config.Environment, config.Generation, 1000, at.Add(config.AppliedRetention), at)
		if err != nil {
			slog.Warn("AppView scope filtering failed", "error", err)
			if err := workerPause(ctx, time.Second); err != nil {
				return err
			}
			continue
		}
		if filtered >= 1000 {
			continue
		}
		items, err := store.Claim(ctx, config.Environment, config.Generation, config.InstanceID, config.Concurrency, at.Add(config.LeaseDuration), at)
		if err != nil {
			slog.Warn("AppView inbox claim failed", "error", err)
			if err := workerPause(ctx, time.Second); err != nil {
				return err
			}
			continue
		}
		var batch sync.WaitGroup
		for _, item := range items {
			batch.Add(1)
			go func(item thinappviewcore.InboxItem) {
				defer batch.Done()
				if err := processor.Process(ctx, item); err != nil && ctx.Err() == nil {
					slog.Warn("AppView inbox persistence failed", "sequence", item.Sequence, "error", err)
				}
			}(item)
		}
		batch.Wait()
		at = time.Now()
		if err := store.AdvanceAppliedWatermark(ctx, config.Environment, config.Generation, at); err != nil {
			slog.Warn("AppView watermark failed", "error", err)
		}
		if err := store.ResolveRecoveredIncidents(ctx, config.Environment, config.Generation, at); err != nil {
			slog.Warn("AppView incident reconciliation failed", "error", err)
		}
		if err := store.ResolveRetiredIncidents(ctx, config.Environment, config.Generation, config.IntakeLease, at); err != nil {
			slog.Warn("AppView retired incident reconciliation failed", "error", err)
		}
		if len(items) == 0 {
			if err := workerPause(ctx, config.PollInterval); err != nil {
				return err
			}
		}
	}
}
func (h *Host) runReconciliations(ctx context.Context) error {
	store := thinappviewcore.InboxStore{DB: h.DB}
	config := h.Config
	for {
		at := time.Now()
		requests, err := store.ClaimReconciliations(ctx, config.Environment, config.Generation, config.InstanceID, min(2, config.Concurrency), at.Add(config.LeaseDuration), at)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			slog.Warn("AppView recovery claim failed", "error", err)
			if err := workerPause(ctx, time.Second); err != nil {
				return err
			}
			continue
		}
		var batch sync.WaitGroup
		for _, request := range requests {
			batch.Add(1)
			go func(request thinappviewcore.ReconciliationRequest) {
				defer batch.Done()
				h.processReconciliation(ctx, request)
			}(request)
		}
		batch.Wait()
		if len(requests) == 0 {
			if err := workerPause(ctx, config.PollInterval); err != nil {
				return err
			}
		}
	}
}
func (h *Host) processReconciliation(ctx context.Context, request thinappviewcore.ReconciliationRequest) {
	config := h.Config
	store := thinappviewcore.InboxStore{DB: h.DB}
	requestID := request.ID
	scope := thinappviewcore.RecoveryContext{Environment: request.Environment, SourceGeneration: request.SourceGeneration, RepoDID: request.RepoDID, WorkerID: config.InstanceID, LeaseToken: request.LeaseToken, Sequence: request.TriggerSequence, RequestID: &requestID}
	workCtx, cancel := context.WithTimeout(ctx, config.RestoreTimeout)
	done := make(chan error, 1)
	go func() {
		ticker := time.NewTicker(config.LeaseDuration / 3)
		defer ticker.Stop()
		for {
			select {
			case <-workCtx.Done():
				done <- nil
				return
			case <-ticker.C:
				at := time.Now()
				if err := store.RenewReconciliation(workCtx, request, config.InstanceID, at.Add(config.LeaseDuration), at); err != nil {
					if workCtx.Err() != nil {
						done <- nil
						return
					}
					done <- err
					cancel()
					return
				}
			}
		}
	}()
	err := h.Projector.RestoreRepository(workCtx, scope)
	cancel()
	renewErr := <-done
	if err == nil {
		err = renewErr
	}
	if ctx.Err() != nil || errors.Is(err, thinappviewcore.ErrRecoveryYielded) {
		return
	}
	at := time.Now()
	if err == nil {
		err = store.CompleteReconciliation(ctx, request, config.InstanceID, at.Add(config.AppliedRetention), at)
	} else {
		slog.Warn("AppView repository recovery failed", "category", recoveryFailureCategory(err))
		delay := InboxRetryDelay(request.AttemptCount+1, rand.Float64())
		err = store.RetryReconciliation(ctx, request, config.InstanceID, "repository_reconciliation_incomplete", at.Add(delay), at)
	}
	if err != nil {
		slog.Warn("AppView recovery persistence failed", "error", err)
	}
}
func (h *Host) runRSS(ctx context.Context) error {
	for {
		feeds, err := (thinappviewcore.RSSStore{DB: h.DB}).ListFeeds(ctx, h.Config.RSSLimit)
		if err == nil {
			for _, feed := range feeds {
				if _, err = h.RSS.Ingest(ctx, feed); err != nil {
					break
				}
			}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			slog.Warn("AppView RSS polling failed", "error", err)
		}
		if err := workerPause(ctx, h.Config.RSSInterval); err != nil {
			return err
		}
	}
}
func (h *Host) runRetention(ctx context.Context) error {
	for {
		deadline := time.Now().Add(30 * time.Second)
		more := true
		for more && time.Now().Before(deadline) {
			at := time.Now()
			counts, err := (thinappviewcore.RetentionStore{DB: h.DB}).DeleteBatch(ctx, h.Config.Environment, at, at.Add(-h.Config.ReadRetention), 1000, false, h.Redis == nil)
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				slog.Warn("AppView retention failed", "error", err)
				break
			}
			more = false
			for _, count := range counts {
				more = more || count >= 1000
			}
			if h.Config.PDSIdleEviction {
				viewer, _, hasMore, err := h.EvictIdleReadState(ctx, at.Add(-time.Duration(h.Config.PDSIdleDays*24)*time.Hour), at, 1000)
				if err != nil {
					slog.Warn("PDS read-state eviction failed", "error", err)
					break
				}
				more = more || hasMore
				if viewer != "" {
					_ = h.Cache.InvalidateViewer(ctx, viewer)
				}
			}
		}
		delay := time.Hour
		if more {
			delay = 10 * time.Second
		}
		if err := workerPause(ctx, delay); err != nil {
			return err
		}
	}
}
