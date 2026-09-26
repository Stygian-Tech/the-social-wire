// schema-ready is an image entrypoint, not a migration runner. It closes its
// database connection before replacing itself with the original application.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/schemaready"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Environ(), logger, syscall.Exec); err != nil {
		logger.Error("Schema readiness prevented startup", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args, environ []string, logger *slog.Logger, execute func(string, []string, []string) error) error {
	return runWithDependencies(ctx, args, environ, logger, execute, schemaready.ReadManifest, schemaready.Wait)
}

func runWithDependencies(ctx context.Context, args, environ []string, logger *slog.Logger,
	execute func(string, []string, []string) error,
	readManifest func(string) ([]string, error),
	wait func(context.Context, string, []string, *slog.Logger) error,
) error {
	if len(args) == 2 && args[0] == "--generate-manifest" {
		versions, err := schemaready.Manifest(args[1])
		if err != nil {
			return err
		}
		fmt.Println(strings.Join(versions, "\n"))
		return nil
	}
	allowLocalSQLite := len(args) > 0 && args[0] == "--allow-local-sqlite"
	if allowLocalSQLite {
		args = args[1:]
	}
	if len(args) < 2 || args[0] != "--" || !strings.HasPrefix(args[1], "/") {
		return errors.New("schema-ready requires -- followed by an absolute application path")
	}
	environment := make(map[string]string)
	for _, value := range environ {
		key, value, _ := strings.Cut(value, "=")
		environment[key] = value
	}
	url, err := schemaready.DatabaseURL(environment, allowLocalSQLite)
	if err != nil {
		return err
	}
	if url != "" {
		versions, err := readManifest("/etc/socialwire/required-migrations.txt")
		if err != nil {
			return err
		}
		waitCtx, cancel := context.WithTimeout(ctx, schemaready.Timeout)
		err = wait(waitCtx, url, versions, logger)
		cancel()
		if err != nil {
			return err
		}
	}
	if ctx.Err() != nil {
		return errors.New("schema readiness canceled")
	}
	if err := execute(args[1], args[1:], environ); err != nil {
		return errors.New("cannot execute application after schema readiness")
	}
	return nil
}
