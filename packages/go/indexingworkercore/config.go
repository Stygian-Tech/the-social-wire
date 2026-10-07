// Package indexingworkercore coordinates independently supervised AppView and Wire lanes.
package indexingworkercore

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

type Role string

const (
	Projection  Role = "projection"
	Coordinator Role = "coordinator"
)

type Config struct {
	Role                                               Role
	Host                                               string
	Port, AppViewHealthPort, WireHealthPort            int
	OwnerID                                            string
	LeaseDuration, RenewInterval, StandbyRetryInterval time.Duration
}

func LoadConfig(env map[string]string) (Config, error) {
	c := Config{Role: Role(strings.ToLower(env["INDEXING_WORKER_ROLE"])), Host: env["BIND_HOST"]}
	if c.Role != Projection && c.Role != Coordinator {
		return c, fmt.Errorf("INDEXING_WORKER_ROLE must be projection or coordinator")
	}
	if c.Host == "" {
		c.Host = "::"
	}
	var err error
	if c.Port, err = port(env, "PORT", 8080); err != nil {
		return c, err
	}
	if c.AppViewHealthPort, err = port(env, "INDEXING_APPVIEW_HEALTH_PORT", c.Port+1); err != nil {
		return c, err
	}
	if c.WireHealthPort, err = port(env, "INDEXING_WIRE_HEALTH_PORT", c.Port+2); err != nil {
		return c, err
	}
	if c.Port == c.AppViewHealthPort || c.Port == c.WireHealthPort || c.AppViewHealthPort == c.WireHealthPort {
		return c, fmt.Errorf("health ports must be distinct")
	}
	if c.LeaseDuration, err = seconds(env, "INDEXING_ROLE_LEASE_SECONDS", 30); err != nil {
		return c, err
	}
	if c.RenewInterval, err = seconds(env, "INDEXING_ROLE_LEASE_RENEW_SECONDS", 10); err != nil {
		return c, err
	}
	if c.StandbyRetryInterval, err = seconds(env, "INDEXING_ROLE_STANDBY_RETRY_SECONDS", 5); err != nil {
		return c, err
	}
	if c.LeaseDuration <= 5*time.Second || c.RenewInterval >= c.LeaseDuration-5*time.Second {
		return c, fmt.Errorf("invalid role lease timing")
	}
	for _, key := range []string{"RAILWAY_REPLICA_ID", "HOSTNAME"} {
		if value := strings.TrimSpace(env[key]); value != "" {
			c.OwnerID = value
			break
		}
	}
	if c.OwnerID == "" {
		c.OwnerID, err = os.Hostname()
		if err != nil {
			return c, err
		}
	}
	return c, nil
}
func (c Config) ControlEvidenceMaximumAge() time.Duration {
	return max(30*time.Second, max(c.RenewInterval, c.StandbyRetryInterval)+5*time.Second)
}
func port(env map[string]string, key string, fallback int) (int, error) {
	value := fallback
	if raw, ok := env[key]; ok {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			return 0, fmt.Errorf("%s must be a positive port", key)
		}
		value = parsed
	}
	if value < 1 || value > 65535 {
		return 0, fmt.Errorf("%s must be a positive port", key)
	}
	return value, nil
}
func seconds(env map[string]string, key string, fallback float64) (time.Duration, error) {
	value := fallback
	if raw, ok := env[key]; ok {
		parsed, err := strconv.ParseFloat(raw, 64)
		if err != nil {
			return 0, fmt.Errorf("%s must be positive seconds", key)
		}
		value = parsed
	}
	if math.IsNaN(value) || math.IsInf(value, 0) || value <= 0 || value >= float64(math.MaxInt64)/float64(time.Second) {
		return 0, fmt.Errorf("%s must be finite positive seconds", key)
	}
	duration := time.Duration(value * float64(time.Second))
	if duration <= 0 {
		return 0, fmt.Errorf("%s is below duration precision", key)
	}
	return duration, nil
}
