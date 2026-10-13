package topics

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
)

// Supply the reads needed for a retained, empty first page, including the
// authoritative snapshot stamp followed by its fenced payload read.
// The registered HTTP route still runs moderation, source/catalog selection,
// snapshot reuse, page rendering, and the actual Finance/Sports encoder.
type feedSerializationConnector struct{ now time.Time }

func (c feedSerializationConnector) Connect(context.Context) (driver.Conn, error) {
	return &feedSerializationConn{now: c.now}, nil
}
func (c feedSerializationConnector) Driver() driver.Driver { return feedSerializationDriver{} }

type feedSerializationDriver struct{}

func (feedSerializationDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("use connector")
}

type feedSerializationConn struct{ now time.Time }

func (*feedSerializationConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (*feedSerializationConn) Close() error { return nil }
func (*feedSerializationConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected mutation")
}
func (c *feedSerializationConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	switch {
	case strings.Contains(query, "FROM sports_entities"), strings.Contains(query, "FROM finance_instruments"):
		return &feedSerializationRows{columns: []string{"payload"}}, nil
	case strings.Contains(query, "FROM sports_personalized_snapshots"), strings.Contains(query, "FROM finance_personalized_snapshots"):
		if strings.Contains(query, "SELECT payload::text") {
			return &feedSerializationRows{columns: []string{"payload"}, values: []driver.Value{"[]"}}, nil
		}
		return &feedSerializationRows{columns: []string{"id", "generated_at", "expires_at", "source", "stamp"}, values: []driver.Value{"22222222-2222-2222-2222-222222222222", c.now, c.now.Add(time.Hour), "ranked", "1:(0,1)"}}, nil
	case strings.Contains(query, "WITH selected AS MATERIALIZED"):
		return &feedSerializationRows{columns: []string{"id", "generated_at", "expires_at", "payload", "source"}, values: []driver.Value{"11111111-1111-1111-1111-111111111111", c.now, c.now.Add(time.Hour), "[]", "ranked"}}, nil
	}
	return nil, errors.New("unexpected SQL in route fixture")
}

type feedSerializationRows struct {
	columns []string
	values  []driver.Value
}

func (r *feedSerializationRows) Columns() []string { return r.columns }
func (*feedSerializationRows) Close() error        { return nil }
func (r *feedSerializationRows) Next(dest []driver.Value) error {
	if r.values == nil {
		return io.EOF
	}
	copy(dest, r.values)
	r.values = nil
	return nil
}

func TestRegisteredTopicFeedRoutesReportSerialization(t *testing.T) {
	for _, family := range []string{"sports", "finance"} {
		t.Run(family, func(t *testing.T) {
			now := time.Now().UTC()
			db := sql.OpenDB(feedSerializationConnector{now})
			defer db.Close()
			var samples []telemetrycore.MetricSample
			buffer := &telemetrycore.TelemetryBuffer{Export: func(_ context.Context, batch []telemetrycore.MetricSample) error {
				samples = append(samples, batch...)
				return nil
			}}
			routes := Routes{Moderation: topicreadcore.NewModerationService(nil, nil), Telemetry: buffer, Now: func() time.Time { return now }}
			env := map[string]string{"WIRE_CURSOR_HMAC_SECRET": strings.Repeat("a", 32), "SPORTS_FEED_MODE": "visible", "FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true"}
			var err error
			if family == "sports" {
				routes.SportsStore, err = topicreadcore.NewSportsStore(db, &topicreadcore.WireStore{}, &topicreadcore.SelectionProjection{}, env)
			} else {
				routes.FinanceStore, err = topicreadcore.NewFinanceStore(db, &topicreadcore.WireStore{}, &topicreadcore.SelectionProjection{}, env)
			}
			if err != nil {
				t.Fatal(err)
			}
			mux := http.NewServeMux()
			routes.Register(mux)
			method := "getSports"
			if family == "finance" {
				method = "getFinance"
			}
			request := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.discovery."+method+"?lang=en&limit=30", nil)
			request.Header.Set("X-Request-ID", "serialization-route-123")
			writer := httptest.NewRecorder()
			writer.Header().Set("X-Request-ID", "serialization-route-123")
			mux.ServeHTTP(writer, request)
			var body map[string]any
			if writer.Code != 200 || json.Unmarshal(writer.Body.Bytes(), &body) != nil || body["source"] != "ranked" || body["items"] == nil {
				t.Fatal(writer.Code, writer.Body.String())
			}
			if !strings.Contains(writer.Header().Get("Server-Timing"), "serialization;dur=") || writer.Header().Get("X-Request-ID") != "serialization-route-123" || writer.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal(writer.Header())
			}
			if _, err := buffer.Flush(context.Background()); err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, sample := range samples {
				if sample.Name == "feed.phase.latency_ms" && sample.Dimensions["phase"] == "serialization" {
					count++
					if sample.Value < 0 || sample.Dimensions["feed"] != family || sample.Dimensions["auth"] != "public" {
						t.Fatal(sample)
					}
				}
			}
			if count != 1 {
				t.Fatal("registered route must emit one serialization metric", samples)
			}
		})
	}
}
