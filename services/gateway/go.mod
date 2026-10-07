module github.com/stygian-tech/the-social-wire/services/gateway

go 1.26.6

require github.com/stygian-tech/the-social-wire/packages/go v0.0.0

require (
	github.com/go-jose/go-jose/v4 v4.1.5 // indirect
	golang.org/x/sync v0.23.0 // indirect
)

replace github.com/stygian-tech/the-social-wire/packages/go => ../../packages/go
