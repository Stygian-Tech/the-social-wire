package main

import (
	"testing"
)

func TestOperationsAuthenticationKeepsTrustSecretsSeparate(t *testing.T) {
	auth := authConfiguration(map[string]string{"GATEWAY_APPVIEW_INTERNAL_SECRET": "unrelated", "GATEWAY_OPERATIONS_INTERNAL_SECRET": "internal", "OAUTH_OPERATIONS_CLIENT_ID": "ops-client", "OAUTH_GATEWAY_ALLOWED_CLIENT_IDS": "one,two", "OAUTH_GATEWAY_ALLOWED_AUDIENCES": "did:web:pds.example", "OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT": "true"})
	if auth.AttestationSecret != "" || auth.PLCURL != "https://plc.directory" || !auth.RequireKnownClient || len(auth.AllowedClientIDs) != 3 || len(auth.AllowedAudiences) != 1 {
		t.Fatal(auth)
	}
	auth = authConfiguration(map[string]string{"PDS_ATTESTATION_RECEIPT_SECRET": "explicit"})
	if auth.AttestationSecret != "explicit" {
		t.Fatal(auth)
	}
}
