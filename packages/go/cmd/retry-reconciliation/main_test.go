package main

import (
	"bytes"
	"context"
	"testing"
)

func TestRetryRequiresExplicitOperatorScopeBeforeConnecting(t *testing.T) {
	valid := []string{"--environment", "prod", "--generation", "fixture-generation", "--expected-count", "4", "--apply"}
	if _, err := parseScope(valid); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{}, valid[:len(valid)-1],
		{"--environment", "prod", "--expected-count", "4", "--apply"},
		{"--environment", "local", "--generation", "fixture", "--expected-count", "4", "--apply"},
		{"--environment", "prod", "--generation", "fixture", "--expected-count", "0", "--apply"},
		{"--environment", "prod", "--generation", "fixture", "--expected-count", "101", "--apply"},
		append(append([]string{}, valid...), "extra"),
	} {
		var output bytes.Buffer
		if err := run(context.Background(), args, "never-connect-to-invalid-scope", &output); err == nil || output.Len() != 0 {
			t.Fatal("invalid invocation did not fail before connecting")
		}
	}
	if err := run(context.Background(), valid, "", &bytes.Buffer{}); err == nil {
		t.Fatal("missing explicit command database admitted")
	}
}
