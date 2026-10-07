package wireworkercore

import "testing"

func TestRollupFixtureRejectsUnsafeTargetsWithoutDialing(t *testing.T) {
	for _, test := range []struct {
		name, dsn string
		accepted  bool
	}{
		{"CI", "postgresql://postgres:postgres@127.0.0.1:5432/socialwire_go_test?sslmode=disable", true},
		{"local", "postgresql://postgres@localhost:55475/tsw155_rollup_test", true},
		{"IPv6", "postgres://postgres@[::1]:55475/tsw155_recovery", true},
		{"hosted", "postgresql://postgres@postgres.railway.internal/tsw155_rollup_test", false},
		{"ordinary name", "postgresql://postgres@127.0.0.1:55475/socialwire", false},
		{"production", "postgresql://postgres@localhost/production", false},
		{"keyword DSN", "host=localhost dbname=tsw155_rollup_test", false},
		{"host override", "postgresql://postgres@localhost/tsw155_rollup_test?host=postgres.railway.internal", false},
		{"database override", "postgresql://postgres@localhost/tsw155_rollup_test?dbname=production", false},
		{"duplicate sslmode", "postgresql://postgres@localhost/tsw155_rollup_test?sslmode=disable&sslmode=require", false},
		{"invalid query", "postgresql://postgres@localhost/tsw155_rollup_test?sslmode=%zz", false},
		{"socket", "postgresql:///tsw155_rollup_test?host=/tmp", false},
		{"fragment", "postgresql://postgres@localhost/tsw155_rollup_test#production", false},
		{"escaped slash", "postgresql://postgres@localhost/tsw155_rollup_test%2fproduction", false},
		{"invalid URL", "postgresql://[::1/tsw155_rollup_test", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := validateRollupFixtureDSN(test.dsn)
			if (err == nil) != test.accepted {
				t.Fatalf("accepted=%v want%v", err == nil, test.accepted)
			}
		})
	}
}
