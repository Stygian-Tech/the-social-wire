package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationsapi"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
)

func main() {
	if err := run(); err != nil {
		slog.Error("Operations stopped", "error_category", "runtime_failed")
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
	for i := 1; i < len(os.Args); i++ {
		switch os.Args[i] {
		case "serve":
		case "--port", "--hostname":
			key := "PORT"
			if os.Args[i] == "--hostname" {
				key = "BIND_HOST"
			}
			if i+1 >= len(os.Args) {
				return errors.New("missing Operations argument value")
			}
			i++
			env[key] = os.Args[i]
		default:
			return errors.New("unknown Operations argument")
		}
	}
	config, err := operationsapi.ConfigFromEnvironment(env)
	if err != nil {
		return err
	}
	port := env["PORT"]
	if port == "" {
		port = "8083"
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return errors.New("invalid Operations port")
	}
	host := env["BIND_HOST"]
	if host == "" {
		host = "::"
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	pgConfig, err := pgxpool.ParseConfig(config.DatabaseURL)
	if err != nil {
		return errors.New("invalid database configuration")
	}
	pgConfig.MaxConns = 8
	pgConfig.MinConns = 0
	pgConfig.MaxConnIdleTime = 30 * time.Second
	pgConfig.ConnConfig.ConnectTimeout = 5 * time.Second
	if raw := env["DATABASE_POOL_MAX_CONNECTIONS"]; raw != "" {
		limit, e := strconv.Atoi(raw)
		if e != nil || limit < 1 || limit > 64 {
			return errors.New("invalid database pool bound")
		}
		pgConfig.MaxConns = int32(limit)
	}
	pool, err := pgxpool.NewWithConfig(ctx, pgConfig)
	if err != nil {
		return err
	}
	defer pool.Close()
	check, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = pool.Ping(check)
	cancel()
	if err != nil {
		return errors.New("database dependency unavailable")
	}
	store, err := operationsapi.NewPostgresStore(pool, config.Environment)
	if err != nil {
		return err
	}
	store.FingerprintSecret = config.FingerprintSecret
	telemetryDB := stdlib.OpenDBFromPool(pool)
	defer telemetryDB.Close()
	exporter := &telemetrycore.PostgresExporter{DB: telemetryDB, Environment: config.Environment}
	store.TelemetryExporter = exporter
	buffer := &telemetrycore.TelemetryBuffer{Export: exporter.Export}
	var webhook *operationsapi.WebhookDelivery
	if config.WebhookURL != "" && config.WebhookSecret != "" {
		webhook = &operationsapi.WebhookDelivery{URL: config.WebhookURL, Secret: config.WebhookSecret, Client: gatewaycore.NewPublicHTTPClient(nil)}
	}
	var version *string
	if value := env["RAILWAY_DEPLOYMENT_ID"]; value != "" {
		version = &value
	}
	background := &operationsapi.Runtime{Store: store, Config: config, Telemetry: buffer, Webhook: webhook, Version: version}
	auth := authConfiguration(env)
	server := &http.Server{Addr: net.JoinHostPort(host, port), Handler: telemetrycore.HTTPTrace(telemetrycore.HTTPTraceConfig{Service: "operations", Environment: config.Environment, InstanceID: config.InstanceID, Region: env["RAILWAY_REPLICA_REGION"], Telemetry: enabledTelemetry(config, buffer)}, operationsapi.NewHandler(store, config, auth, nil)), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
	completed := make(chan error, 1)
	go func() { completed <- server.ListenAndServe() }()
	backgroundDone := make(chan struct{})
	go func() { defer close(backgroundDone); _ = background.Run(ctx) }()
	select {
	case err = <-completed:
		stop()
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if shutdownErr := server.Shutdown(shutdown); shutdownErr != nil {
		_ = server.Close()
		if err == nil {
			err = shutdownErr
		}
	}
	<-backgroundDone
	if err == nil || errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
func authConfiguration(env map[string]string) gatewaycore.AuthConfig {
	split := func(raw string) []string {
		return strings.FieldsFunc(raw, func(ch rune) bool { return ch == ',' || ch == ' ' || ch == '\n' || ch == '\t' })
	}
	truthy := func(raw string) bool {
		switch strings.ToLower(raw) {
		case "1", "true", "yes", "on":
			return true
		}
		return false
	}
	secret := env["PDS_ATTESTATION_RECEIPT_SECRET"]
	plc := env["ATPROTO_PLC_URL"]
	if plc == "" {
		plc = "https://plc.directory"
	}
	return gatewaycore.AuthConfig{PLCURL: plc, SupplementalJWKS: env["OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON"], AttestationSecret: secret, RequireKnownClient: truthy(env["OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT"]), AllowedClientIDs: split(env["OAUTH_GATEWAY_ALLOWED_CLIENT_IDS"] + " " + env["OAUTH_OPERATIONS_CLIENT_ID"]), AllowedAudiences: split(env["OAUTH_GATEWAY_ALLOWED_AUDIENCES"])}
}

func enabledTelemetry(config operationsapi.Config, buffer *telemetrycore.TelemetryBuffer) *telemetrycore.TelemetryBuffer {
	if config.Enabled {
		return buffer
	}
	return nil
}
