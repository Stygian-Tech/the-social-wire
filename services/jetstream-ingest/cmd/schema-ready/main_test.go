package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"reflect"
	"testing"
)

func TestApplicationOnlyExecutesAfterReadinessAndPreservesArguments(t *testing.T) {
	for _, failure := range []bool{false, true} {
		ready, executed := false, false
		args := []string{"--", "/usr/local/bin/IndexingWorker", "--role", "projection"}
		env := []string{"APP_ENV=dev", "DATABASE_URL=postgres://database", "INDEXING_WORKER_ROLE=projection"}
		err := runWithDependencies(context.Background(), args, env, slog.New(slog.NewTextHandler(io.Discard, nil)),
			func(path string, argv, environ []string) error {
				if !ready || path != args[1] || !reflect.DeepEqual(argv, args[1:]) || !reflect.DeepEqual(environ, env) {
					t.Fatal("exec before readiness or arguments changed")
				}
				executed = true
				return nil
			},
			func(path string) ([]string, error) {
				if path != "/etc/socialwire/required-migrations.txt" {
					t.Fatal("mutable manifest selection")
				}
				return []string{"20260926190000"}, nil
			},
			func(ctx context.Context, url string, versions []string, _ *slog.Logger) error {
				if _, ok := ctx.Deadline(); !ok {
					t.Fatal("missing bounded wait")
				}
				if failure {
					return errors.New("missing migration")
				}
				ready = true
				return nil
			})
		if executed == failure || (err != nil) != failure {
			t.Fatalf("failure=%v, executed=%v, err=%v", failure, executed, err)
		}
	}
}

func TestLocalSQLiteAndCancellation(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		if canceled {
			cancel()
		}
		executed := false
		err := run(ctx, []string{"--allow-local-sqlite", "--", "/usr/local/bin/AppView"}, nil, slog.Default(), func(string, []string, []string) error { executed = true; return nil })
		cancel()
		if executed == canceled || (err != nil) != canceled {
			t.Fatalf("canceled=%v, executed=%v, err=%v", canceled, executed, err)
		}
	}
}

func TestMissingManifestAndInvalidArgumentsNeverExecute(t *testing.T) {
	for _, args := range [][]string{nil, {"--", "relative"}, {"--", "/usr/local/bin/AppView"}} {
		err := runWithDependencies(context.Background(), args, []string{"APP_ENV=dev", "DATABASE_URL=postgres://db"}, slog.Default(),
			func(string, []string, []string) error { t.Fatal("executed without manifest"); return nil },
			func(string) ([]string, error) { return nil, errors.New("missing manifest") },
			func(context.Context, string, []string, *slog.Logger) error {
				t.Fatal("waited without manifest")
				return nil
			})
		if err == nil {
			t.Fatal("accepted invalid startup")
		}
	}
}

func TestCancellationAfterDatabaseReadinessStillPreventsExec(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	err := runWithDependencies(ctx, []string{"--", "/usr/local/bin/IndexingWorker"},
		[]string{"APP_ENV=dev", "DATABASE_URL=postgres://db"}, slog.Default(),
		func(string, []string, []string) error { t.Fatal("executed canceled startup"); return nil },
		func(string) ([]string, error) { return []string{"20260926190000"}, nil },
		func(context.Context, string, []string, *slog.Logger) error { cancel(); return nil })
	if err == nil {
		t.Fatal("accepted canceled startup")
	}
}
