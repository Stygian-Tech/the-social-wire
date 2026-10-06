# gatewaycore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/gatewaycore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

DecodePayload uses UnsafePayloadWithoutVerification deliberately for inspection. No route may use successful decoding as authorization. Issuer binding, signatures, DPoP, replay checks, and internal Gateway/AppView trust remain outside this implementation. DNS admission must be coupled to pinned-address dialing and redirect revalidation.

## Source map

| File | Responsibility |
| --- | --- |
| [compact_jwt.go](compact_jwt.go) | Uses go-jose to parse a signed compact envelope without verifying its signature. Payloads remain raw JSON to preserve exact numbers. ATH hashing is a DPoP helper; neither operation authenticates the caller. |
| [public_dns.go](public_dns.go) | Bounds concurrent DNS admission and rejects an HTTPS endpoint if any answer is special-use or private. Address selection is deterministic. Callers must pin the admitted address when dialing and revalidate redirects to avoid DNS rebinding. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./gatewaycore`.

[public_dns_test.go](public_dns_test.go) covers:

- `TestPublicAddressPolicy`
- `TestMixedDNSAnswersFailClosed`
- `TestPayloadInspectionRejectsNonObjects`
- `TestPayloadInspectionUsesJOSEAndRejectsUnsignedTokens`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- issuer-bound OAuth and DPoP verification adapters
- gateway/appview internal trust
- repo discovery and PDS clients
- OAuth metadata and remaining service contracts
