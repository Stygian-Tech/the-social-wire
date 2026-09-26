package schemaready

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const Timeout = 90 * time.Second

// DatabaseURL mirrors the image's backend selection. Only Gateway/AppView allow
// SQLite locally. A hosted image can never silently bypass the migration gate.
func DatabaseURL(environment map[string]string, allowLocalSQLite bool) (string, error) {
	appEnv := strings.TrimSpace(environment["APP_ENV"])
	// GatewayCore parses APP_ENV without trimming and otherwise selects SQLite.
	// Do not accept a value here that the unchanged child environment interprets
	// as another backend. The Postgres-only workers do trim their environment.
	if allowLocalSQLite && appEnv != environment["APP_ENV"] {
		return "", errors.New("schema readiness requires a canonical APP_ENV value")
	}
	hosted := environment["RAILWAY_ENVIRONMENT_ID"] != "" || environment["RAILWAY_SERVICE_ID"] != ""
	if allowLocalSQLite && !hosted && (appEnv == "" || appEnv == "local") {
		return "", nil
	}
	if appEnv != "dev" && appEnv != "prod" {
		return "", errors.New("schema readiness requires APP_ENV=dev or prod")
	}
	url := strings.TrimSpace(environment["DATABASE_URL"])
	if url == "" {
		return "", errors.New("schema readiness requires DATABASE_URL")
	}
	return url, nil
}

type connection interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Close(context.Context) error
}

type connector func(context.Context) (connection, error)

// Wait uses one short-lived, read-only connection, never an application pool.
// No transaction is retained between polls: each check sees committed receipts.
func Wait(ctx context.Context, url string, versions []string, logger *slog.Logger) error {
	config, err := pgx.ParseConfig(url)
	if err != nil {
		return errors.New("invalid schema readiness database configuration")
	}
	config.ConnectTimeout = 5 * time.Second
	config.RuntimeParams["application_name"] = "socialwire-schema-ready"
	config.RuntimeParams["default_transaction_read_only"] = "on"
	config.RuntimeParams["statement_timeout"] = "5000"
	config.RuntimeParams["lock_timeout"] = "1000"
	return wait(ctx, func(ctx context.Context) (connection, error) {
		conn, err := pgx.ConnectConfig(ctx, config)
		if err != nil {
			return nil, err
		}
		return conn, nil
	}, versions, logger, time.Second)
}

const missingQuery = `SELECT count(*) FROM unnest($1::text[]) AS required(version)
WHERE NOT EXISTS (SELECT 1 FROM public.schema_migrations AS applied WHERE applied.version = required.version)`

func wait(ctx context.Context, connect connector, versions []string, logger *slog.Logger, interval time.Duration) error {
	var conn connection
	closeConnection := func() {
		if conn != nil {
			closeCtx, cancel := context.WithTimeout(context.Background(), time.Second)
			_ = conn.Close(closeCtx)
			cancel()
			conn = nil
		}
	}
	defer closeConnection()
	lastState := ""
	for {
		if ctx.Err() != nil {
			return errors.New("schema readiness canceled or timed out")
		}
		queryCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		var err error
		if conn == nil {
			conn, err = connect(queryCtx)
		}
		var missing int
		if err == nil {
			err = conn.QueryRow(queryCtx, missingQuery, versions).Scan(&missing)
		}
		cancel()
		if err == nil && missing == 0 {
			if ctx.Err() != nil {
				return errors.New("schema readiness canceled or timed out")
			}
			logger.Info("Required schema migrations are ready", "required_versions", len(versions))
			return nil
		}
		state := "missing_receipts"
		if err != nil {
			// Never log connection errors verbatim: they can contain credentials.
			state = "database_unavailable"
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) {
				if pgErr.Code == "42501" || pgErr.Code == "28P01" || pgErr.Code == "28000" {
					return errors.New("schema readiness database permission or authentication denied")
				}
				if pgErr.Code == "42P01" {
					state = "missing_ledger"
				}
			}
			closeConnection()
		}
		if state != lastState {
			logger.Info("Waiting for required schema migrations", "state", state, "missing_versions", missing)
			lastState = state
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return errors.New("schema readiness canceled or timed out")
		case <-timer.C:
		}
	}
}
