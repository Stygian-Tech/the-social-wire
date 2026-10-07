// Package control reserves Coordinator authority and failure-diagnostic connections
// independently of AppView and Wire workload pools.
package control

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

// Database owns the two control pools. Projection workers do not allocate them.
// The caller closes these pools only after both owned lanes finish teardown.
type Database struct {
	Authority   *sql.DB
	Diagnostics *sql.DB
	LeaseStore  *operationscore.PostgresRoleLeaseStore
}

// Open validates the environment before allocating independent pools. It does not
// acquire a lease, migrate the schema, or open a workload connection.
func Open(databaseURL, environment string) (*Database, error) {
	environment = strings.ToLower(strings.TrimSpace(environment))
	if environment != "dev" && environment != "prod" {
		return nil, errors.New("APP_ENV must be dev or prod")
	}
	if strings.TrimSpace(databaseURL) == "" {
		return nil, errors.New("DATABASE_URL is required")
	}
	configuration, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		// Parse failures can contain credentials; expose only the field involved.
		return nil, errors.New("DATABASE_URL is invalid")
	}
	if configuration.ConnectTimeout == 0 || configuration.ConnectTimeout > 3*time.Second {
		configuration.ConnectTimeout = 3 * time.Second
	}
	authorityConfiguration := configuration.Copy()
	authorityConfiguration.RuntimeParams["application_name"] = "indexing-authority"
	authorityPool := stdlib.OpenDB(*authorityConfiguration)
	authorityPool.SetMaxOpenConns(2)
	authorityPool.SetMaxIdleConns(2)
	diagnosticConfiguration := configuration.Copy()
	diagnosticConfiguration.RuntimeParams["application_name"] = "indexing-lease-diagnostics"
	diagnosticPool := stdlib.OpenDB(*diagnosticConfiguration)
	diagnosticPool.SetMaxOpenConns(1)
	diagnosticPool.SetMaxIdleConns(0)
	diagnosticPool.SetConnMaxIdleTime(10 * time.Second)
	return &Database{
		Authority: authorityPool, Diagnostics: diagnosticPool,
		LeaseStore: &operationscore.PostgresRoleLeaseStore{DB: authorityPool, Environment: environment},
	}, nil
}

// Close joins both pool closures without allowing a diagnostic failure to skip
// releasing the authority pool.
func (database *Database) Close() error {
	return errors.Join(database.Diagnostics.Close(), database.Authority.Close())
}
