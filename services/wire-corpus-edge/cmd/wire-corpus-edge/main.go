package main

import (
	"context"
	"github.com/stygian-tech/the-social-wire/services/wire-corpus-edge/internal/edge"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	env := map[string]string{}
	for _, entry := range os.Environ() {
		if key, value, ok := strings.Cut(entry, "="); ok {
			env[key] = value
		}
	}
	if err := edge.Run(ctx, env, os.Args[1:]); err != nil {
		slog.Error("Wire Corpus Edge stopped unsuccessfully")
		os.Exit(1)
	}
}
