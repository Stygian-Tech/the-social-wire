module github.com/stygian-tech/the-social-wire/services/wire-corpus-edge

go 1.26.6

require (
	github.com/jackc/pgx/v5 v5.7.6
	github.com/redis/go-redis/v9 v9.23.0
	github.com/stygian-tech/the-social-wire/packages/go v0.0.0
)

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/sony/gobreaker/v2 v2.4.0 // indirect
	go.uber.org/atomic v1.12.0 // indirect
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

replace github.com/stygian-tech/the-social-wire/packages/go => ../../packages/go
