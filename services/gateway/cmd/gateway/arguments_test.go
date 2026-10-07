package main

import "testing"

func TestServeCLIOverridesEnvironmentAndRejectsMissingValues(t *testing.T) {
	env := map[string]string{"PORT": "8080"}
	if err := parseArguments(env, []string{"serve", "--port", "9000", "--hostname", "127.0.0.1"}); err != nil || env["PORT"] != "9000" || env["BIND_HOST"] != "127.0.0.1" {
		t.Fatal(env, err)
	}
	for _, args := range [][]string{{"--port"}, {"serve", "--hostname"}, {"--port", "--hostname", "a"}, {"unrecognized"}, {"serve", "serve"}} {
		if parseArguments(map[string]string{}, args) == nil {
			t.Fatal("invalid args accepted", args)
		}
	}
}
