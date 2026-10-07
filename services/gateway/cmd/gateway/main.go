package main

import (
	"context"
	"database/sql"
	"errors"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/services/gateway/internal/gateway"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	if err := run(); err != nil {
		slog.Error("Gateway stopped", "error_category", "runtime_failed")
		os.Exit(1)
	}
}
func run() error {
	env := map[string]string{}
	for _, item := range os.Environ() {
		k, v, ok := strings.Cut(item, "=")
		if ok {
			env[k] = v
		}
	}
	if err := parseArguments(env, os.Args[1:]); err != nil {
		return err
	}
	config, e := gateway.ParseConfig(env)
	if e != nil {
		return e
	}
	if config.CacheBackend == "sqlite" {
		return errors.New("Go Gateway requires PostgreSQL or Redis cache")
	}
	if config.DatabaseURL == "" {
		return errors.New("Go Gateway requires canonical DATABASE_URL")
	}
	db, e := sql.Open("pgx", config.DatabaseURL)
	if e != nil {
		return e
	}
	defer db.Close()
	pool := 8
	if value, err := strconv.Atoi(env["DATABASE_POOL_MAX_CONNECTIONS"]); err == nil && value > 0 && value <= 64 {
		pool = value
	}
	db.SetMaxOpenConns(pool)
	db.SetMaxIdleConns(1)
	db.SetConnMaxIdleTime(30 * time.Second)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	authLifetime := gatewaycore.NewAuthLifetime(ctx)
	config.Auth.Lifetime = authLifetime
	check, cancel := context.WithTimeout(ctx, 5*time.Second)
	e = db.PingContext(check)
	cancel()
	if e != nil {
		return errors.New("database dependency unavailable")
	}
	var redisClient *redis.Client
	if config.RedisURL != "" {
		if opts, err := redis.ParseURL(config.RedisURL); err == nil {
			opts.PoolSize = 8
			opts.MinIdleConns = 1
			opts.DialTimeout = 3 * time.Second
			opts.ReadTimeout = 250 * time.Millisecond
			opts.WriteTimeout = 250 * time.Millisecond
			opts.MaxRetries = -1
			opts.ContextTimeoutEnabled = true
			redisClient = redis.NewClient(opts)
			defer redisClient.Close()
		}
	}
	public := gatewaycore.NewPublicHTTPClient(nil)
	defer public.CloseIdleConnections()
	namespace := socialwireredis.NewKeyNamespace(config.Environment, "")
	cache := &gateway.RecordCache{DB: db, Redis: redisClient, Backend: config.CacheBackend, Namespace: namespace}
	preferences := &gateway.Preferences{Repo: &gatewaycore.RepoClient{Client: public, PLCURL: config.Auth.PLCURL}, Cache: cache, Context: ctx}
	service := &gateway.Server{Config: config, DB: db, Public: public, Preferences: preferences, Limiter: &gateway.RequestLimiter{Redis: redisClient, Namespace: namespace}, Region: env["RAILWAY_REPLICA_REGION"]}
	telemetryEnabled := env["OPERATIONS_TELEMETRY_ENABLED"] == "" || memberTruthy(env["OPERATIONS_TELEMETRY_ENABLED"])
	if telemetryEnabled {
		exporter := &telemetrycore.PostgresExporter{DB: db, Environment: config.Environment}
		service.Telemetry = &telemetrycore.TelemetryBuffer{Export: exporter.Export}
	}
	service.InstanceID = env["RAILWAY_REPLICA_ID"]
	if service.InstanceID == "" {
		service.InstanceID, _ = os.Hostname()
	}
	server := &http.Server{Addr: config.Address, Handler: service.Handler(), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
	var workers sync.WaitGroup
	workers.Add(1)
	go func() { defer workers.Done(); service.Collect(ctx) }()
	if telemetryEnabled {
		workers.Add(2)
		go func() { defer workers.Done(); _ = service.Telemetry.Run(ctx) }()
		go func() {
			defer workers.Done()
			instance := env["RAILWAY_REPLICA_ID"]
			if instance == "" {
				instance, _ = os.Hostname()
			}
			service.Heartbeat(ctx, instance, env["RAILWAY_DEPLOYMENT_ID"], time.Now().UTC())
		}()
	}
	errCh := make(chan error, 1)
	go func() { errCh <- server.ListenAndServe() }()
	slog.Info("Gateway started", "runtime", "go", "go_version", runtime.Version(), "environment", config.Environment)
	select {
	case <-ctx.Done():
	case e = <-errCh:
		stop()
	}
	shutdown, done := context.WithTimeout(context.Background(), 10*time.Second)
	defer done()
	if err := server.Shutdown(shutdown); err != nil {
		server.Close()
	}
	stop()
	joined := make(chan struct{})
	go func() { workers.Wait(); preferences.Wait(); close(joined) }()
	select {
	case <-joined:
		if err := authLifetime.Close(shutdown); err != nil {
			return errors.New("authentication shutdown did not join shared work")
		}
	case <-shutdown.Done():
		slog.Error("Gateway shutdown did not join owned workers")
		os.Exit(1)
	}
	if service.Telemetry != nil {
		_, _ = service.Telemetry.Flush(shutdown)
	}
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return e
}

func memberTruthy(value string) bool {
	switch strings.ToLower(value) {
	case "true", "1", "yes", "on":
		return true
	}
	return false
}
