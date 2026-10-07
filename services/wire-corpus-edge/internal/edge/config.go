package edge

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
)

type Config struct {
	DatabaseURL, SharedSecret, AllowedServiceID string
	MaximumConnections                          int
}

var serviceIDPattern = regexp.MustCompile(`^[a-zA-Z0-9._-]{1,64}$`)

func LoadConfig(env map[string]string) (Config, error) {
	value := func(key string) string { return strings.TrimSpace(env[key]) }
	appEnv := strings.ToLower(env["APP_ENV"])
	if appEnv != "dev" && appEnv != "prod" {
		return Config{}, errors.New("unsupported corpus environment")
	}
	c := Config{DatabaseURL: value("DATABASE_URL"), SharedSecret: value("WIRE_CORPUS_EDGE_SHARED_SECRET"), AllowedServiceID: value("WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID"), MaximumConnections: 4}
	if c.DatabaseURL == "" {
		return c, errors.New("missing corpus database URL")
	}
	if len([]byte(c.SharedSecret)) < 32 {
		return c, errors.New("invalid corpus shared secret")
	}
	if !serviceIDPattern.MatchString(c.AllowedServiceID) {
		return c, errors.New("invalid corpus allowed service ID")
	}
	if count, err := strconv.Atoi(env["WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS"]); err == nil {
		c.MaximumConnections = max(1, min(8, count))
	}
	return c, nil
}
