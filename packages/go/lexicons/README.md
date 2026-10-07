# lexicons

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/lexicons`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Regenerate bundles from packages/lexicons JSON. Documents and Resolve return independent decoded/copied data, protecting the embedded registry from caller mutation. Lookup is not Lexicon value validation; do not replace the existing validator with schema existence checks.

## Source map

| File | Responsibility |
| --- | --- |
| [registry.go](registry.go) | Loads independent copies of canonical Lexicon documents and resolves default, named, or relative definitions. Schema lookup does not validate a record against the schema; typed models and value validation remain migration work. |
| [contracts_generated.go](contracts_generated.go) | Generated canonical schema/contract data. Edit the canonical source and generator, never this output. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./lexicons`.

[registry_test.go](registry_test.go) covers:

- `TestGeneratedLexiconsMatchCanonicalSources`
- `TestLexiconDefinitionsAreIsolated`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- typed generated models
- Lexicon value validation and format conformance
