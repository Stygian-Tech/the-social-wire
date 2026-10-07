package runner

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/indexing-worker/internal/control"
)

func TestFailureDiagnosticPostgresSnapshot(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set isolated SOCIALWIRE_GO_TEST_DATABASE_URL")
	}
	pools, err := control.Open(url, "dev")
	if err != nil {
		t.Fatal(err)
	}
	defer pools.Close()
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	if _, err := connection.ExecContext(ctx, `SET application_name='postgresql://fixture:private-password@private-host/private-db'`); err != nil {
		t.Fatal(err)
	}
	sleeping, stopSleep := context.WithCancel(ctx)
	defer stopSleep()
	done := make(chan error, 1)
	go func() { _, err := connection.ExecContext(sleeping, "SELECT pg_sleep(4)"); done <- err }()
	// Confirm the backend is active before taking a bounded snapshot.
	for deadline := time.Now().Add(time.Second); ; {
		var active int
		if err := pools.Authority.QueryRowContext(ctx, `SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'postgresql://fixture:%' AND state='active'`).Scan(&active); err != nil {
			t.Fatal(err)
		}
		if active > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fixture backend did not become active")
		}
		time.Sleep(5 * time.Millisecond)
	}
	o := newObserver(pools.Diagnostics, "dev", "fixture", slog.New(slog.NewTextHandler(io.Discard, nil)))
	snapshot, err := o.loadSnapshot(ctx, "indexing.appview-coordinator")
	if err != nil {
		t.Fatal(err)
	}
	stopSleep()
	<-done
	raw, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"private-password", "private-host", "private-db", "pg_sleep"} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("diagnostic leaked %s", secret)
		}
	}
	if snapshot["connections_active"].(int64) < 1 {
		t.Fatal("active backend evidence missing")
	}
	if pools.Authority.Stats().MaxOpenConnections != 2 || pools.Diagnostics.Stats().MaxOpenConnections != 1 {
		t.Fatal("diagnostics competed for authority capacity")
	}
}

func TestExecuteRealDomainHostsAndHealth(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set isolated SOCIALWIRE_GO_TEST_DATABASE_URL")
	}
	for _, role := range []string{"projection", "coordinator"} {
		t.Run(role, func(t *testing.T) {
			ports := []int{}
			reserved := []net.Listener{}
			for range 3 {
				listener, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				reserved = append(reserved, listener)
				ports = append(ports, listener.Addr().(*net.TCPAddr).Port)
			}
			for _, listener := range reserved {
				listener.Close()
			}
			env := map[string]string{"INDEXING_WORKER_ROLE": role, "APP_ENV": "dev", "DATABASE_URL": url, "BIND_HOST": "127.0.0.1", "PORT": strconv.Itoa(ports[0]), "INDEXING_APPVIEW_HEALTH_PORT": strconv.Itoa(ports[1]), "INDEXING_WIRE_HEALTH_PORT": strconv.Itoa(ports[2]), "RAILWAY_REPLICA_ID": "entrypoint-test", "ENABLE_THIN_APPVIEW": "true", "THIN_APPVIEW_JETSTREAM_MODE": "v2_authoritative", "THIN_APPVIEW_RSS_FEED_POLL_ENABLED": "false", "OPERATIONS_TELEMETRY_ENABLED": "false", "WIRE_FEED_MODE": "off"}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				done <- Execute(ctx, env, nil, slog.New(slog.NewTextHandler(io.Discard, nil)), func(indexingworkercore.LaneName) { t.Error("shutdown watchdog fired") })
			}()
			client := &http.Client{Timeout: time.Second}
			target := "http://127.0.0.1:" + strconv.Itoa(ports[0]) + "/startupz"
			started := false
			for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
				response, err := client.Get(target)
				if err == nil {
					_, _ = io.Copy(io.Discard, response.Body)
					response.Body.Close()
					if response.StatusCode == 200 {
						started = true
						break
					}
				}
				select {
				case err := <-done:
					t.Fatalf("runtime exited before startup: %v", err)
				default:
				}
				time.Sleep(10 * time.Millisecond)
			}
			cancel()
			select {
			case err := <-done:
				if err != nil && !IsCancellation(err) {
					t.Fatalf("unclean runtime teardown: %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("runtime did not join")
			}
			if !started {
				t.Fatal("composed AppView and Wire hosts did not establish startup evidence")
			}
		})
	}
}
