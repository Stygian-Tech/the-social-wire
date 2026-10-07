package config

import (
	"strings"
	"testing"
)

func fixture() map[string]string {
	return map[string]string{"APP_ENV": "prod", "DATABASE_URL": "postgres://local/test", "ENABLE_THIN_APPVIEW": "true"}
}
func TestAppViewHostedAndLocalConfigFailClosed(t *testing.T) {
	base := fixture()
	c, err := Parse(base)
	if err != nil || c.Address != "[::]:8081" || c.PodcastsEnabled || !c.TelemetryEnabled || c.WireMode != "off" {
		t.Fatal(c, err)
	}
	for _, pair := range [][2]string{{"DATABASE_URL", ""}, {"ENABLE_THIN_APPVIEW", "false"}, {"APPVIEW_CACHE_BACKEND", "sqlite"}, {"CIRCLE_FEED_MODE", "shadow"}, {"PORT", "0"}} {
		env := fixture()
		env[pair[0]] = pair[1]
		if _, err := Parse(env); err == nil {
			t.Fatal(pair)
		}
	}
	base["APP_ENV"] = "local"
	base["PODCASTS_ENABLED"] = "TRUE"
	base["OPERATIONS_TELEMETRY_ENABLED"] = "false"
	c, err = Parse(base)
	if err != nil || !c.PodcastsEnabled || c.TelemetryEnabled {
		t.Fatal(c, err)
	}
}
func TestAppViewDiscoveryCorpusEnvironmentBoundary(t *testing.T) {
	env := fixture()
	env["APP_ENV"] = "dev"
	env["SPORTS_FEED_MODE"] = "visible"
	env["WIRE_CURSOR_HMAC_SECRET"] = strings.Repeat("x", 32)
	if _, err := Parse(env); err == nil {
		t.Fatal("missing Development corpus accepted")
	}
	env["WIRE_CORPUS_EDGE_BASE_URL"] = "http://corpus.railway.internal"
	env["WIRE_CORPUS_EDGE_SERVICE_ID"] = "appview"
	env["WIRE_CORPUS_EDGE_HMAC_SECRET"] = strings.Repeat("c", 32)
	c, err := Parse(env)
	if err != nil || c.WireMode != "visible" || c.WireRemote == nil {
		t.Fatal(c, err)
	}
	env["APP_ENV"] = "prod"
	env["WIRE_CORPUS_EDGE_BASE_URL"] = "https://corpus.example"
	if _, err = Parse(env); err == nil {
		t.Fatal("remote Production Wire accepted")
	}
}
func TestPostgresPoolUsesDeployedSourceKey(t *testing.T) {
	for _, test := range []struct {
		raw  string
		want int
	}{{"", 2}, {"bad", 2}, {"-1", 2}, {"1", 2}, {"6", 6}, {"100", 100}} {
		env := fixture()
		env["POSTGRES_MAX_CONNECTIONS"] = test.raw
		c, e := Parse(env)
		if e != nil || c.MaximumConnections != test.want {
			t.Fatal(test, c, e)
		}
	}
}
