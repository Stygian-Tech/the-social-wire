// retry-reconciliation is an explicit operator action, never a worker startup hook.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type retryScope struct {
	environment, generation string
	expectedCount           int
}

func parseScope(args []string) (retryScope, error) {
	var scope retryScope
	flags := flag.NewFlagSet("retry-reconciliation", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&scope.environment, "environment", "", "exact dev or prod scope")
	flags.StringVar(&scope.generation, "generation", "", "exact source generation")
	flags.IntVar(&scope.expectedCount, "expected-count", 0, "exact eligible failed request count")
	apply := flags.Bool("apply", false, "explicitly authorize the scoped retry")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || !*apply || (scope.environment != "dev" && scope.environment != "prod") || scope.generation == "" || scope.expectedCount < 1 || scope.expectedCount > thinappviewcore.MaximumOperatorReconciliationRetries {
		return retryScope{}, thinappviewcore.ErrReconciliationRetryScope
	}
	return scope, nil
}

func run(ctx context.Context, args []string, dsn string, output io.Writer) error {
	scope, err := parseScope(args)
	if err != nil {
		return err
	}
	// Never fall back to DATABASE_URL. The operator must explicitly supply this
	// command's database variable, keeping credentials out of arguments/output.
	if dsn == "" {
		return thinappviewcore.ErrReconciliationRetryScope
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		return thinappviewcore.ErrReconciliationRetryScope
	}
	config.ConnectTimeout = 5 * time.Second
	config.RuntimeParams["application_name"] = "socialwire-operator-reconciliation-retry"
	db := stdlib.OpenDB(*config)
	db.SetMaxOpenConns(1)
	defer db.Close()
	budget, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	count, err := (thinappviewcore.InboxStore{DB: db}).OperatorRetryFailedReconciliations(budget, scope.environment, scope.generation, scope.expectedCount, time.Now().UTC())
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(output, "requeued_requests=%d historical_attempts_preserved=true\n", count)
	return err
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv("RECONCILIATION_RETRY_DATABASE_URL"), os.Stdout); err != nil {
		category := "retry_failed"
		if errors.Is(err, thinappviewcore.ErrReconciliationRetryScope) {
			category = "invalid_scope"
		} else if errors.Is(err, thinappviewcore.ErrReconciliationRetryCount) {
			category = "expected_count_mismatch"
		}
		// Connection/SQL errors may contain private identities or credentials.
		fmt.Fprintln(os.Stderr, category)
		os.Exit(1)
	}
}
