# spec

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/spec`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Regenerate from packages/spec/endpoint-manifest.json and openapi.yaml. OpenAPIDocument returns an upstream libopenapi document; callers build its V3 model and handle model/reference errors. No route registration, HTTP serving, or authentication is introduced here.

## Source map

| File | Responsibility |
| --- | --- |
| [contracts.go](contracts.go) | Reads the generated canonical endpoint manifest and looks up exact surface/path pairs with an uppercase method. An endpoint classification describes the contract, not runtime route availability. |
| [openapi.go](openapi.go) | Returns libopenapi documents directly so callers use the upstream OpenAPI 3.1 model/reference implementation. Building a model is separate from creating the document and from checking service route conformance. |
| [contracts_generated.go](contracts_generated.go) | Generated canonical schema/contract data. Edit the canonical source and generator, never this output. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./spec`.

[contracts_test.go](contracts_test.go) covers:

- `TestGeneratedAPIContractsMatchCanonicalSources`
- `TestCanonicalOpenAPIBuildsWith31Parser`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- remaining service/route conformance checks
