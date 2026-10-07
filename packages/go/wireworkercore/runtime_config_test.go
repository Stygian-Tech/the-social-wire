package wireworkercore

import (
	"strings"
	"testing"
)

func TestRuntimeConfigTopicsRequireWireEvenWhenPublicWireIsOff(t *testing.T) {
	for _, key := range []string{"FINANCE_FEED_MODE", "SPORTS_FEED_MODE"} {
		env := map[string]string{"DATABASE_URL": "postgres://localhost/test", key: "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true"}
		if _, err := LoadRuntimeConfig(env, "drain"); err == nil {
			t.Fatalf("%s allowed topic ingestion without actor secret", key)
		}
		env["WIRE_ACTOR_HMAC_SECRET"] = strings.Repeat("x", 32)
		config, err := LoadRuntimeConfig(env, "drain")
		if err != nil {
			t.Fatal(err)
		}
		if config.Cycle.Mode != "api" {
			t.Fatalf("effective mode %q", config.Cycle.Mode)
		}
	}
}
func TestRuntimeConfigScopeAndBounds(t *testing.T) {
	base := map[string]string{"DATABASE_URL": "postgres://localhost/test", "APP_ENV": "dev", "WIRE_INBOX_SOURCE_GENERATIONS": "v2, v2,snapshot"}
	c, err := LoadRuntimeConfig(base, "drain")
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Scope.Generations) != 2 || c.Scope.Environment != "dev" {
		t.Fatalf("scope %#v", c.Scope)
	}
	for key, value := range map[string]string{"WIRE_INBOX_CONCURRENCY": "65", "WIRE_METADATA_BATCH_SIZE": "251", "WIRE_INBOX_CLEANUP_ENABLED": "1", "WIRE_INBOX_SOURCE_GENERATIONS": "v2,", "APP_ENV": "local"} {
		env := map[string]string{}
		for k, v := range base {
			env[k] = v
		}
		env[key] = value
		if _, err := LoadRuntimeConfig(env, "rank"); err == nil {
			t.Fatalf("accepted invalid %s", key)
		}
	}
}
func TestParseLabelersRejectsAmbiguousAuthorities(t *testing.T) {
	for _, raw := range []string{"", "did:example:a|http://example.com", "did:example:a|https://u:p@example.com", "did:example:a|https://example.com?", "did:example:a|https://example.com, did:example:a|https://other.com"} {
		if _, err := ParseLabelers(raw); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}
