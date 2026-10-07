// wire-replay-drain is a disposable replay evidence tool, not a hosted service class.
package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/stygian-tech/the-social-wire/packages/go/wireworkercore"
)

func validate(environment map[string]string) error {
	dsn, err := url.Parse(environment["DATABASE_URL"])
	if err != nil || (dsn.Scheme != "postgresql" && dsn.Scheme != "postgres") || !regexp.MustCompile(`^/tsw92_[a-z0-9_]+$`).MatchString(dsn.Path) {
		return errors.New("disposable tsw92 database required")
	}

	// Reject connection targets hidden in libpq environment or URL query overrides.
	// Validate the same effective pgx configuration that sql.Open will use.
	for key, value := range environment {
		if strings.HasPrefix(key, "PG") && value != "" {
			return errors.New("libpq environment overrides are not permitted in replay")
		}
	}
	query, err := url.ParseQuery(dsn.RawQuery)
	if err != nil {
		return errors.New("invalid replay connection query")
	}
	for key, values := range query {
		if (key != "sslmode" && key != "connect_timeout") || len(values) != 1 {
			return errors.New("replay connection query overrides are not permitted")
		}
	}
	configuration, err := pgx.ParseConfig(environment["DATABASE_URL"])
	if err != nil || configuration.Database != strings.TrimPrefix(dsn.Path, "/") {
		return errors.New("effective replay database differs from explicit scope")
	}
	if err := validateEffectiveTarget(configuration.Host, configuration.Port); err != nil {
		return err
	}
	for _, fallback := range configuration.Fallbacks {
		if err := validateEffectiveTarget(fallback.Host, fallback.Port); err != nil {
			return err
		}
		if fallback.Host != configuration.Host || fallback.Port != configuration.Port {
			return errors.New("alternate replay connection targets are not permitted")
		}
	}
	if environment["BIND_HOST"] != "127.0.0.1" || environment["APP_ENV"] != "dev" || environment["WIRE_INBOX_SOURCE_GENERATIONS"] == "" {
		return errors.New("explicit Development replay scope and loopback listener required")
	}
	if environment["WIRE_FEED_MODE"] != "shadow" || environment["WIRE_EXTERNAL_SIGNAL_MODE"] != "off" {
		return errors.New("replay must remain shadow with external signals disabled")
	}
	return nil
}
func validateEffectiveTarget(hostname string, port uint16) error {
	local := hostname == "127.0.0.1" || hostname == "localhost" || hostname == "::1"
	isolated := strings.HasPrefix(hostname, "tsw92-") && strings.HasSuffix(hostname, ".railway.internal")
	if port == 0 || (!(local && port != 5432) && !isolated) {
		return errors.New("dedicated replay database required")
	}
	return nil
}

func run(ctx context.Context, environment map[string]string) error {
	if err := validate(environment); err != nil {
		return err
	}
	port, err := strconv.Atoi(environment["PORT"])
	if err != nil || port < 1024 || port > 65535 {
		return errors.New("explicit unprivileged replay port required")
	}
	host, err := wireworkercore.NewHost(environment, "drain")
	if err != nil {
		return err
	}
	defer host.DB.Close()
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	for _, path := range []string{"/health", "/startupz", "/readyz"} {
		route := path
		mux.HandleFunc(route, func(w http.ResponseWriter, r *http.Request) {
			probe := host.Startup
			if route == "/readyz" {
				probe = host.Ready
			}
			budget, stop := context.WithTimeout(r.Context(), 2*time.Second)
			defer stop()
			w.Header().Set("Content-Type", "application/json")
			if probe(budget) != nil {
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(`{"status":"unavailable"}`))
				return
			}
			_, _ = w.Write([]byte(`{"status":"ok"}`))
		})
	}
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second}
	results := make(chan error, 2)
	go func() { results <- host.Run(child, nil) }()
	go func() { results <- server.Serve(listener) }()
	received := 0
	var result error
	select {
	case result = <-results:
		received = 1
	case <-ctx.Done():
		result = ctx.Err()
	}
	cancel()
	shutdown, stop := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	if err := server.Shutdown(shutdown); err != nil {
		_ = server.Close()
	}
	stop()
	for received < 2 {
		err := <-results
		received++
		if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, http.ErrServerClosed) {
			result = errors.Join(result, err)
		}
	}
	return result
}
func main() {
	environment := map[string]string{}
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			environment[key] = value
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, environment); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "replay drain failed")
		os.Exit(1)
	}
}
