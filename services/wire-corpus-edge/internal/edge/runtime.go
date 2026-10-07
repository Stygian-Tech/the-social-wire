package edge

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func OpenDatabase(config Config) (*sql.DB, error) {
	parsed, err := pgx.ParseConfig(config.DatabaseURL)
	if err != nil {
		return nil, errors.New("invalid corpus database URL")
	}
	db := stdlib.OpenDB(*parsed)
	db.SetMaxOpenConns(config.MaximumConnections)
	db.SetMaxIdleConns(config.MaximumConnections)
	return db, nil
}
func Run(ctx context.Context, env map[string]string, args []string) error {
	config, err := LoadConfig(env)
	if err != nil {
		return err
	}
	options := flag.NewFlagSet("wire-corpus-edge", flag.ContinueOnError)
	host := options.String("hostname", env["BIND_HOST"], "listen address")
	portDefault := 8080
	if value, e := strconv.Atoi(env["PORT"]); e == nil {
		portDefault = value
	}
	port := options.Int("port", portDefault, "listen port")
	if err := options.Parse(args); err != nil {
		return err
	}
	if options.NArg() != 0 || *port < 0 || *port > 65535 {
		return errors.New("invalid corpus listen configuration")
	}
	if *host == "" {
		*host = "::"
	}
	db, err := OpenDatabase(config)
	if err != nil {
		return err
	}
	defer db.Close()
	store := &corpuscore.PostgreSQLStore{DB: db}
	var client *redis.Client
	if strings.ToLower(env["WIRE_CORPUS_REDIS_CACHE_ENABLED"]) != "false" {
		url, exists := env["WIRE_CORPUS_REDIS_URL"]
		if !exists {
			url = env["REDIS_URL"]
		}
		if url != "" {
			options, e := redis.ParseURL(url)
			if e != nil {
				slog.Warn("Wire public payload cache unavailable; using PostgreSQL")
			} else {
				options.PoolSize = 4
				options.MinIdleConns = 0
				options.DialTimeout = 2 * time.Second
				options.ReadTimeout = 2 * time.Second
				options.WriteTimeout = 2 * time.Second
				options.MaxRetries = 0
				client = redis.NewClient(options)
				defer client.Close()
				store.Cache = corpuscore.NewPayloadCache(socialwireredis.RedisCommands{Client: client}, env["APP_ENV"], "")
			}
		}
	}
	server := &http.Server{Addr: net.JoinHostPort(*host, strconv.Itoa(*port)), Handler: NewHandler(store, config), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20}
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return fmt.Errorf("corpus listener unavailable")
	}
	finished := make(chan error, 1)
	go func() { finished <- server.Serve(listener) }()
	select {
	case err := <-finished:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		err := server.Shutdown(shutdown)
		if err != nil {
			_ = server.Close()
		}
		<-finished
		return err
	}
}
