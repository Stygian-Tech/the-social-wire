package main

import "testing"

func TestReplayRejectsLiveAndUnboundedTargets(t *testing.T) {
	base := map[string]string{"DATABASE_URL": "postgresql://test@127.0.0.1:55439/tsw92_replay", "APP_ENV": "dev", "BIND_HOST": "127.0.0.1", "WIRE_INBOX_SOURCE_GENERATIONS": "fixture-only", "WIRE_FEED_MODE": "shadow", "WIRE_EXTERNAL_SIGNAL_MODE": "off"}
	if err := validate(base); err != nil {
		t.Fatal(err)
	}
	for key, value := range map[string]string{"DATABASE_URL": "postgresql://test@127.0.0.1:5432/production", "APP_ENV": "prod", "BIND_HOST": "0.0.0.0", "WIRE_INBOX_SOURCE_GENERATIONS": "", "WIRE_FEED_MODE": "visible", "WIRE_EXTERNAL_SIGNAL_MODE": "visible"} {
		changed := map[string]string{}
		for k, v := range base {
			changed[k] = v
		}
		changed[key] = value
		if validate(changed) == nil {
			t.Fatal("unsafe target accepted", key)
		}
	}
}

func TestReplayRejectsEffectiveConnectionOverrides(t *testing.T) {
	base := map[string]string{"DATABASE_URL": "postgresql://test@127.0.0.1:55439/tsw92_replay", "APP_ENV": "dev", "BIND_HOST": "127.0.0.1", "WIRE_INBOX_SOURCE_GENERATIONS": "fixture-only", "WIRE_FEED_MODE": "shadow", "WIRE_EXTERNAL_SIGNAL_MODE": "off"}
	for _, query := range []string{"host=production.example&port=5432&dbname=production", "host=production.example", "port=5432", "dbname=production", "database=production", "service=production", "host=127.0.0.1,production.example", "sslmode=disable&sslmode=require", "sslmode=disable;host=production.example"} {
		changed := map[string]string{}
		for k, v := range base {
			changed[k] = v
		}
		changed["DATABASE_URL"] += "?" + query
		if validate(changed) == nil {
			t.Fatal("query override accepted", query)
		}
	}
	for _, key := range []string{"PGHOST", "PGHOSTADDR", "PGPORT", "PGDATABASE", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS"} {
		changed := map[string]string{}
		for k, v := range base {
			changed[k] = v
		}
		changed[key] = "production"
		if validate(changed) == nil {
			t.Fatal("libpq override accepted", key)
		}
	}
	for _, hostname := range []string{"production.example", "/private/tmp", "127.0.0.1"} {
		if validateEffectiveTarget(hostname, 5432) == nil {
			t.Fatal("unsafe fallback accepted", hostname)
		}
	}
	for _, dsn := range []string{"postgresql://test@localhost:55439/tsw92_replay?sslmode=prefer", "postgresql://test@tsw92-postgres.railway.internal/tsw92_replay?sslmode=disable"} {
		changed := map[string]string{}
		for k, v := range base {
			changed[k] = v
		}
		changed["DATABASE_URL"] = dsn
		if err := validate(changed); err != nil {
			t.Fatal("isolated target rejected", err)
		}
	}
}
