package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"github.com/stygian-tech/the-social-wire/services/indexing-worker/internal/runner"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	env := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			env[key] = value
		}
	}
	err := runner.Execute(ctx, env, os.Args[1:], logger, func(lane indexingworkercore.LaneName) {
		logger.Error("Cancelled indexing lane failed to stop; terminating process", "lane", lane)
		os.Exit(1)
	})
	if err != nil && !runner.IsCancellation(err) {
		// Database and publisher failures may carry credentials or source payloads.
		// Startup failure is intentionally a closed operational signal.
		logger.Error("Indexing worker stopped unsuccessfully")
		os.Exit(1)
	}
}
