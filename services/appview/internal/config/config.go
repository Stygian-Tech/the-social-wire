package config

import (
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net"
	"os"
	"strconv"
	"strings"
)

// Config selects only PostgreSQL-backed Go stores. Local runs require an explicit
// DATABASE_URL; the Swift SQLite backend is not silently substituted.
type Config struct {
	Environment, Address, DatabaseURL, RedisURL, CacheBackend, InternalSecret, InstanceID, Version, Region, WireSecret, WireMode string
	MaximumConnections                                                                                                           int
	PodcastsEnabled, TelemetryEnabled                                                                                            bool
	Auth                                                                                                                         gatewaycore.AuthConfig
	Modes                                                                                                                        map[string]string
	WireRemote, FinanceRemote, SportsRemote                                                                                      *corpuscore.RemoteConfig
	EnvironmentValues                                                                                                            map[string]string
}

func Parse(env map[string]string) (Config, error) {
	c := Config{Environment: strings.ToLower(strings.TrimSpace(env["APP_ENV"])), DatabaseURL: env["DATABASE_URL"], RedisURL: env["REDIS_URL"], InternalSecret: env["GATEWAY_APPVIEW_INTERNAL_SECRET"], Version: env["RAILWAY_DEPLOYMENT_ID"], Region: env["RAILWAY_REPLICA_REGION"], MaximumConnections: 2, Modes: map[string]string{}, EnvironmentValues: map[string]string{}}
	for k, v := range env {
		c.EnvironmentValues[k] = v
	}
	if c.Environment != "dev" && c.Environment != "prod" && c.Environment != "local" {
		return c, errors.New("APP_ENV must identify local, dev or prod")
	}
	if strings.TrimSpace(c.DatabaseURL) == "" {
		return c, errors.New("Go AppView requires explicit PostgreSQL DATABASE_URL")
	}
	if !Truthy(env["ENABLE_THIN_APPVIEW"]) {
		return c, errors.New("ENABLE_THIN_APPVIEW must be true")
	}
	for _, name := range []string{"WIRE", "CIRCLE", "FINANCE", "SPORTS"} {
		mode := strings.ToLower(env[name+"_FEED_MODE"])
		if mode == "" {
			mode = "off"
		}
		if mode != "off" && mode != "api" && mode != "visible" && (mode != "shadow" || name == "CIRCLE") {
			return c, errors.New("invalid discovery mode")
		}
		c.Modes[strings.ToLower(name)] = mode
	}
	var err error
	c.WireRemote, err = corpuscore.RemoteConfigFromEnvironment(env)
	if err != nil {
		return c, err
	}
	for _, topic := range []string{"FINANCE", "SPORTS"} {
		remote, e := corpuscore.RemoteConfigFromEnvironment(map[string]string{"APP_ENV": c.Environment, "WIRE_CORPUS_EDGE_BASE_URL": env[topic+"_CORPUS_EDGE_BASE_URL"], "WIRE_CORPUS_EDGE_SERVICE_ID": env[topic+"_CORPUS_EDGE_SERVICE_ID"], "WIRE_CORPUS_EDGE_HMAC_SECRET": env[topic+"_CORPUS_EDGE_HMAC_SECRET"]})
		if e != nil {
			return c, e
		}
		if topic == "FINANCE" {
			c.FinanceRemote = remote
		} else {
			c.SportsRemote = remote
		}
	}
	discovery := c.Serves("wire") || c.Serves("circle") || c.Serves("finance") || c.Serves("sports")
	if c.Environment == "dev" && discovery && c.WireRemote == nil {
		return c, errors.New("Development discovery requires the authorized Corpus Edge")
	}
	if c.Environment == "prod" && (c.WireRemote != nil || c.SportsRemote != nil) {
		return c, errors.New("Production Wire and Sports use their local serving corpus")
	}
	if c.Serves("circle") {
		for _, key := range []string{"WIRE_ACTOR_HMAC_SECRET", "CIRCLE_CURSOR_HMAC_SECRET"} {
			if len(strings.TrimSpace(env[key])) < 32 {
				return c, errors.New("Circle requires complete HMAC configuration")
			}
		}
	}
	c.WireMode = "off"
	if discovery {
		c.WireMode = "api"
		if c.Serves("wire") {
			c.WireMode = c.Modes["wire"]
		} else {
			for _, mode := range c.Modes {
				if mode == "visible" {
					c.WireMode = "visible"
				}
			}
		}
		c.WireSecret = strings.TrimSpace(env["WIRE_CURSOR_HMAC_SECRET"])
		if c.WireSecret == "" {
			c.WireSecret = strings.TrimSpace(env["CIRCLE_CURSOR_HMAC_SECRET"])
		}
		if c.WireSecret == "" {
			c.WireSecret = env["FINANCE_CURSOR_HMAC_SECRET"]
		}
		if len(c.WireSecret) < 32 {
			return c, errors.New("discovery requires Wire cursor HMAC secret")
		}
	}
	c.CacheBackend = strings.ToLower(env["APPVIEW_CACHE_BACKEND"])
	if c.CacheBackend == "" {
		c.CacheBackend = "postgres"
	}
	if c.CacheBackend != "postgres" && c.CacheBackend != "redis" {
		return c, errors.New("Go AppView projection cache requires postgres or redis")
	}
	port := 8081
	if raw, exists := env["PORT"]; exists {
		port, err = strconv.Atoi(raw)
		if err != nil || port < 1 || port > 65535 {
			return c, errors.New("invalid PORT")
		}
	}
	host := env["BIND_HOST"]
	if host == "" {
		host = "::"
	}
	c.Address = net.JoinHostPort(host, strconv.Itoa(port))
	if value, e := strconv.Atoi(env["POSTGRES_MAX_CONNECTIONS"]); e == nil {
		c.MaximumConnections = max(2, value)
	}

	c.InstanceID = env["RAILWAY_REPLICA_ID"]
	if c.InstanceID == "" {
		c.InstanceID, _ = os.Hostname()
	}
	c.PodcastsEnabled = strings.EqualFold(env["PODCASTS_ENABLED"], "true")
	c.TelemetryEnabled = true
	if raw, exists := env["OPERATIONS_TELEMETRY_ENABLED"]; exists {
		c.TelemetryEnabled = Truthy(raw)
	}
	plc := env["ATPROTO_PLC_URL"]
	if plc == "" {
		plc = "https://plc.directory"
	}
	secret := strings.TrimSpace(env["PDS_ATTESTATION_RECEIPT_SECRET"])
	if secret != "" && (len(secret) < 32 || len(secret) > 4096) {
		return c, errors.New("invalid PDS attestation receipt secret")
	}
	c.Auth = gatewaycore.AuthConfig{PLCURL: plc, SupplementalJWKS: env["OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON"], AttestationSecret: secret, RequireKnownClient: Truthy(env["OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT"]), AllowedClientIDs: Split(env["OAUTH_GATEWAY_ALLOWED_CLIENT_IDS"] + " " + env["OAUTH_OPERATIONS_CLIENT_ID"]), AllowedAudiences: Split(env["OAUTH_GATEWAY_ALLOWED_AUDIENCES"])}
	return c, nil
}
func (c Config) Serves(name string) bool { return c.Modes[name] == "api" || c.Modes[name] == "visible" }
func Truthy(value string) bool {
	switch strings.ToLower(value) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}
func Split(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' || r == '\t' })
}
