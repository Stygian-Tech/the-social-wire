package control

import (
	"strings"
	"testing"
)

func TestControlPoolsReserveIndependentCapacity(t *testing.T) {
	database, err := Open("postgresql://localhost/isolated_conformance?sslmode=disable", " DEV ")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	if database.Authority == database.Diagnostics || database.Authority.Stats().MaxOpenConnections != 2 || database.Diagnostics.Stats().MaxOpenConnections != 1 {
		t.Fatal("authority and diagnostics must have independently reserved capacity")
	}
	if database.LeaseStore.DB != database.Authority || database.LeaseStore.Environment != "dev" {
		t.Fatal("lease store must use the scoped authority pool")
	}
}

func TestControlConfigurationFailsWithoutExposingCredentials(t *testing.T) {
	for _, input := range []struct{ databaseURL, environment string }{
		{"postgresql://localhost/test", ""},
		{"postgresql://localhost/test", "staging"},
		{"", "dev"},
		{"postgresql://secret-user:secret-password@%invalid/test", "dev"},
	} {
		database, err := Open(input.databaseURL, input.environment)
		if err == nil || database != nil {
			t.Fatal("invalid authority configuration must fail before pool allocation")
		}
		if strings.Contains(err.Error(), "secret") {
			t.Fatal("configuration errors must not expose connection credentials")
		}
	}
}
