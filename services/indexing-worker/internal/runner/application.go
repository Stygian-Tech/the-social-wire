package runner

import (
	"context"
	"errors"
	"flag"
	"io"
	"log/slog"
	"net"
	goruntime "runtime"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/services/indexing-worker/internal/control"
	"github.com/stygian-tech/the-social-wire/services/indexing-worker/internal/health"
)

// Configuration preserves Swift's --port and --hostname overrides while applying
// the same strict environment and distinct component-port validation.
func Configuration(environment map[string]string, arguments []string) (map[string]string, indexingworkercore.Config, error) {
	flags := flag.NewFlagSet("indexing-worker", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var port, hostname string
	flags.StringVar(&port, "port", "", "public health port")
	flags.StringVar(&hostname, "hostname", "", "health bind hostname")
	if err := flags.Parse(arguments); err != nil {
		return nil, indexingworkercore.Config{}, errors.New("invalid command options")
	}
	if flags.NArg() != 0 {
		return nil, indexingworkercore.Config{}, errors.New("unexpected command arguments")
	}
	env := map[string]string{}
	for key, value := range environment {
		env[key] = value
	}
	flags.Visit(func(f *flag.Flag) {
		if f.Name == "port" {
			env["PORT"] = port
		}
		if f.Name == "hostname" {
			env["BIND_HOST"] = hostname
		}
	})
	config, err := indexingworkercore.LoadConfig(env)
	if err != nil {
		return nil, config, err
	}
	env["APP_ENV"] = strings.ToLower(strings.TrimSpace(env["APP_ENV"]))
	if env["APP_ENV"] != "dev" && env["APP_ENV"] != "prod" {
		return nil, config, errors.New("APP_ENV must be dev or prod")
	}
	if env["DATABASE_URL"] == "" {
		return nil, config, errors.New("DATABASE_URL is required")
	}
	if _, err := pgx.ParseConfig(env["DATABASE_URL"]); err != nil {
		return nil, config, errors.New("DATABASE_URL is invalid")
	}
	return env, config, nil
}

// Execute allocates no control pool for Projection. Coordinator closes its
// separate diagnostic and authority pools only after Runtime has joined lanes.
func Execute(ctx context.Context, environment map[string]string, arguments []string, logger *slog.Logger, terminate func(indexingworkercore.LaneName)) error {
	env, config, err := Configuration(environment, arguments)
	if err != nil {
		return err
	}
	var database *control.Database
	var store operationscore.RoleLeaseStore
	if config.Role == indexingworkercore.Coordinator {
		database, err = control.Open(env["DATABASE_URL"], env["APP_ENV"])
		if err != nil {
			return err
		}
		defer database.Close()
		store = database.LeaseStore
	}
	runtime, err := indexingworkercore.NewRuntime(config, factories(env, config), store)
	if err != nil {
		return err
	}
	runtime.Terminate = terminate
	runtime.OnComponentError = func(lane indexingworkercore.LaneName, _ error) {
		logger.Error("Indexing component restarting", "lane", lane)
	}
	if database != nil {
		observer := newObserver(database.Diagnostics, env["APP_ENV"], config.OwnerID, logger)
		observerContext, stopObserver := context.WithCancel(context.WithoutCancel(ctx))
		observerDone := make(chan struct{})
		go func() { defer close(observerDone); observer.run(observerContext) }()
		defer func() { stopObserver(); <-observerDone }()
		runtime.OnEvent = observer.event
	}
	listener, err := net.Listen("tcp", net.JoinHostPort(config.Host, strconv.Itoa(config.Port)))
	if err != nil {
		return errors.New("public health listener unavailable")
	}
	logger.Info("Starting consolidated indexing worker", "role", config.Role, "owner_id", config.OwnerID, "runtime", "go", "go_version", goruntime.Version())
	return serve(ctx, listener, health.Handler(config.Role, runtime), runtime.Run)
}
