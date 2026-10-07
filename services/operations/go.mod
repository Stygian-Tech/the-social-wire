module github.com/stygian-tech/the-social-wire/services/operations

go 1.26.6

require (
	github.com/jackc/pgx/v5 v5.7.6
	github.com/stygian-tech/the-social-wire/packages/go v0.0.0
)

require (
	github.com/go-jose/go-jose/v4 v4.1.5 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

replace github.com/stygian-tech/the-social-wire/packages/go => ../../packages/go
