package gateway

import (
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/url"
	"strconv"
	"strings"
)

type Config struct {
	Environment, Address, DatabaseURL, RedisURL, CacheBackend                 string
	AppViewURL, OperationsURL, ProjectionURL, LatrURL                         string
	AppViewSecret, OperationsSecret, LatrClientID, LatrAPIKey, LatrCredential string
	PublicOrigin, IOSOrigin, OperationsOrigin                                 string
	Modes                                                                     map[string]string
	AllowedOrigins                                                            []string
	Auth                                                                      gatewaycore.AuthConfig
}

func ParseConfig(env map[string]string) (Config, error) {
	get := func(k, f string) string {
		v := strings.TrimSpace(env[k])
		if v == "" {
			return f
		}
		return v
	}
	c := Config{Environment: get("APP_ENV", "local"), DatabaseURL: get("DATABASE_URL", ""), RedisURL: get("REDIS_URL", ""), AppViewURL: get("APPVIEW_BASE_URL", ""), OperationsURL: get("OPERATIONS_BASE_URL", ""), ProjectionURL: get("PROJECTION_POOL_BASE_URL", get("CHARYBDIS_BASE_URL", "")), LatrURL: get("LATR_IOS_PROXY_URL", ""), AppViewSecret: get("GATEWAY_APPVIEW_INTERNAL_SECRET", ""), OperationsSecret: get("GATEWAY_OPERATIONS_INTERNAL_SECRET", ""), LatrClientID: get("LATR_IOS_PROXY_CLIENT_ID", ""), LatrAPIKey: get("LATR_IOS_PROXY_API_KEY", ""), LatrCredential: get("LATR_IOS_PROXY_CLIENT_CREDENTIAL", ""), PublicOrigin: get("OAUTH_PUBLIC_ORIGIN", ""), IOSOrigin: get("OAUTH_IOS_METADATA_ORIGIN", ""), OperationsOrigin: get("OAUTH_OPERATIONS_ORIGIN", ""), Modes: map[string]string{}}
	if c.Environment != "local" && c.Environment != "dev" && c.Environment != "prod" {
		return c, fmt.Errorf("APP_ENV must be local, dev or prod")
	}
	if c.Environment != "local" && c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL required in hosted environments")
	}
	port, err := strconv.Atoi(get("PORT", "8080"))
	if err != nil || port < 1 || port > 65535 {
		return c, fmt.Errorf("invalid PORT")
	}
	c.Address = fmt.Sprintf("%s:%d", get("BIND_HOST", ""), port)
	c.CacheBackend = get("GATEWAY_PDS_CACHE_BACKEND", "postgres")
	if c.CacheBackend != "postgres" && c.CacheBackend != "redis" && c.CacheBackend != "sqlite" {
		return c, fmt.Errorf("invalid PDS cache backend")
	}
	for _, name := range []string{"WIRE", "CIRCLE", "FINANCE", "SPORTS"} {
		v := get(name+"_FEED_MODE", "off")
		switch v {
		case "off", "shadow", "api", "visible":
		default:
			return c, fmt.Errorf("invalid %s_FEED_MODE", name)
		}
		c.Modes[strings.ToLower(name)] = v
	}
	for _, base := range []string{c.AppViewURL, c.OperationsURL, c.ProjectionURL} {
		if base == "" {
			continue
		}
		u, e := url.Parse(base)
		if e != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return c, fmt.Errorf("invalid internal service base URL")
		}
	}
	if c.LatrURL != "" {
		if _, e := gatewaycore.NormalizePublicRemoteBase(c.LatrURL); e != nil {
			return c, fmt.Errorf("invalid LATR_IOS_PROXY_URL: %w", e)
		}
	}
	secret := get("PDS_ATTESTATION_RECEIPT_SECRET", "")
	if secret == "" && c.Environment == "local" {
		secret = "local-only-pds-attestation-receipt-secret"
	}
	if len(secret) < 32 || len(secret) > 4096 {
		return c, fmt.Errorf("attestation receipt secret must contain 32..4096 bytes")
	}
	c.Auth = gatewaycore.AuthConfig{PLCURL: get("ATPROTO_PLC_URL", "https://plc.directory"), SupplementalJWKS: get("OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON", ""), AttestationSecret: secret, RequireKnownClient: truthy(env["OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT"]), AllowedClientIDs: split(get("OAUTH_GATEWAY_ALLOWED_CLIENT_IDS", "") + " " + get("OAUTH_OPERATIONS_CLIENT_ID", "")), AllowedAudiences: split(env["OAUTH_GATEWAY_ALLOWED_AUDIENCES"])}
	c.AllowedOrigins = split(env["CORS_ALLOWED_ORIGINS"])
	if len(c.AllowedOrigins) == 0 && c.PublicOrigin != "" {
		c.AllowedOrigins = append(c.AllowedOrigins, c.PublicOrigin)
	}
	if c.OperationsOrigin != "" {
		c.AllowedOrigins = append(c.AllowedOrigins, c.OperationsOrigin)
	}
	if c.Environment == "local" {
		c.AllowedOrigins = append(c.AllowedOrigins, "http://localhost:3000", "http://localhost:3001", "http://127.0.0.1:3000", "http://127.0.0.1:3001")
	}
	return c, nil
}
func split(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' || r == '\t' })
}
func truthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}
func (c Config) Serves(name string) bool { v := c.Modes[name]; return v == "api" || v == "visible" }
