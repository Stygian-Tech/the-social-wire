# internal/signedcursor

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/internal/signedcursor`. See the [module guide](../../README.md) for toolchains and shared verification.

## Responsibilities

Only packages within this module may import this internal codec. The constructor requires at least 32 secret bytes and copies them. Decode bounds encoded input to 4,096 characters, rejects alternate base64url spellings, and verifies HMAC before JSON decoding. Public wrappers remain responsible for versions, required fields, viewer binding, and expiry.

## Source map

| File | Responsibility |
| --- | --- |
| [codec.go](codec.go) | Provides the shared HMAC-SHA256 cursor envelope: unpadded base64url JSON plus an authenticated signature. Secrets are copied, signatures compared in constant time, and noncanonical encodings rejected. Public cursor wrappers enforce domain-specific fields. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./internal/signedcursor`.
