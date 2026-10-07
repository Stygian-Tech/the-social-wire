# Go verification and deployment

This guide covers repository-local Go runtime verification. See [[Architecture]] for service boundaries and [[Service-API]] for the public contracts; the source inventory records the retained package contracts.

## Local checks

Run from the repository root with Go 1.26, Swift 6.2.4, Python 3 and Bash:

```sh
python3 scripts/go/generate-contracts.py --check
python3 scripts/go/package-inventory.py --check
GOWORK=off go -C packages/go vet ./...
GOWORK=off go -C packages/go test -race -p 1 ./...
bash scripts/go/verify-ranking-parity.sh
bash scripts/go/verify-edition-parity.sh
bash scripts/go/verify-domain-ranking-parity.sh
bash scripts/check-wiki-links.sh
git diff --check
```

The Go command must be the language toolchain binary. A different executable named `go` is not a supported compiler. Set explicit toolchain paths where necessary; services and Docker builds resolve the repository-local module rather than a published copy.

## What the evidence proves

| Verification | Evidence and limits |
| --- | --- |
| Wire ranker | 30 actual Swift/Go snapshots: keys/order/reasons/diagnostics exact, score absolute tolerance `1e-12`. Fixtures include age, signal and quality boundaries, diversity and seeded inputs. |
| Edition assembler | 35 actual Swift/Go snapshots comparing complete decoded JSON, including story/account allocation and bounded serving fields. |
| Finance/Sports rankers | 45 actual Swift/Go snapshots of ranked IDs. This does not verify article analysis, reviewed catalogs, provider rights, or complete serving JSON. |
| Read-state | Shared canonical v2 hash fixtures, restricted values/output bounds, original-intent normalization, receipt chains and immutable projection tests. Full sync/compaction/strict loading remains pending. |
| Role authority | PostgreSQL 17 takeover, same-owner token retention, stale authority rejection, expiry after lock wait, shared publication fences permitting renewal while blocking revocation. Supervisor tests require joining before release and watchdog cancellation independent of renewal. |
| Generation store | Canonical-schema metadata projection equality, baseline/external rollup isolation, language discovery, atomic regional editions, stale-fence rollback, shadow-pointer isolation and retention. |
| Parsing/cache/contracts | Fractional feed dates, actual-instant sorting, JSON Feed, tokenizer comment/entity handling, SDK record objects and exact integers, stale breaker completions, one recovery probe, Redis expiry, canonical schema and OpenAPI drift. |

Passing unit tests with PostgreSQL cases skipped does not verify database behavior. Fixture parity is bounded evidence, not a claim that every source declaration or worker job has migrated. Circle and full cursor/canonicalization/trust differential coverage remain pending even though local contract regression tests exist.

## Disposable PostgreSQL

Use a disposable PostgreSQL 17 instance. Apply the canonical migration history with `scripts/apply-database-migrations.sh` before generation tests, then set:

```sh
export SOCIALWIRE_GO_TEST_DATABASE_URL='postgresql://.../disposable_test?sslmode=disable'
export SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL='postgresql://.../disposable_test?sslmode=disable'
GOWORK=off go -C packages/go test -race -count=1 ./operationscore ./wireworkercore
```

The lease suite installs its existing lease migrations; the generation suite expects the full canonical schema. The dedicated test variables intentionally do not read the hosted `DATABASE_URL`. These tests write/delete fixtures and run retention, so never point them at Development or Production. PostgreSQL ownership/publication behavior is validated with real transactions, not a SQL mock.

## Generated data and scripts

| Tool/artifact | Purpose |
| --- | --- |
| `scripts/go/generate-contracts.py` | Embeds canonical Lexicons, endpoint manifest and OpenAPI, rejects duplicate IDs, and computes the OpenAPI digest. Change comments here for generated output. |
| `scripts/go/package-inventory.py` | Records canonical source paths/digests/declarations/tests and service-library targets. Refresh only after reviewing changed contracts. |
| `migration/source-inventory.json` | Source baseline rather than a parity or deployment claim. |
| `migration/status.json` | Separate implemented/pending surfaces and verification scope; service activation remains pending. |
| `verify-*-parity.sh` | Compiles actual Swift and Go commands in temporary directories and removes build artifacts on exit. |
| `verify-*-parity.py` | Uses fixed clocks/seeds and compares the stated outputs; every failed assertion exits nonzero. |
| `*-oracle.swift` and `packages/go/cmd/*-parity` | Test-only JSON stdin/stdout bridges. No authority acquisition, hosted storage, worker loops or HTTP serving. |

The domain oracle compiles actual rankers/models, extracts resolver constants and normalization helpers, and supplies only required hierarchy identities. It does not implement a substitute resolver. [Tooling README](https://github.com/Stygian-Tech/the-social-wire/blob/dev/scripts/go/README.md) and [command README](https://github.com/Stygian-Tech/the-social-wire/blob/dev/packages/go/cmd/README.md) document every driver/bridge.

## CI and image dependencies

The Repository-local Go Packages job checks generated contracts and source inventory, runs vet/race tests, applies canonical migrations to PostgreSQL 17, executes database integration cases, and runs all three Swift/Go differential drivers. The aggregate **CI — required** includes this job; a failure cannot be treated as an optional migration check.

Path detection treats shared Go source, contract sources and verification scripts as Go-check inputs. Changes to `packages/go/go.mod` or `go.sum` also affect service-image jobs because shared manifests participate in repository schema-gate build contexts. Ingress directly resolves the shared module; current Swift image gates need the manifests for reproducible Go module resolution. Dockerfiles copy both manifests before the gate runs. Watch paths include the shared manifests for Gateway, AppView, compatibility workers, Wire worker, Operations, Ingress and the Development podcast worker. Config tests cover those dependencies.

Root Bun workspaces use `bun install --frozen-lockfile` in CI. Commit reviewed `bun.lock` updates after workspace changes. Generated contract checks are distinct from inventory checks, and wiki navigation is checked by the Documentation job.

## Development delivery

`dev` deploys to Railway Development; `main` deploys to Production. Source integration, config-as-code selection, migrations, and health are separate verification points. See [[Deployment-and-environments]].

1. Rebase/cherry-pick the feature onto current `dev` without introducing unrelated Production branch history. Pass the protected PR’s required CI checks, then merge the checked head into `dev`.
2. Check Railway in the explicitly selected Development environment. Confirm the deployment’s source branch and commit hash match the merged revision. Inspect build/runtime logs on failures rather than inferring success from a Git push.
3. Confirm prerequisite migrations succeeded. This foundation introduces no new database migration; do not rerun hosted migrations merely because a library changed.
4. Wait for rolling deployments to settle, verify running/total replicas, absence of crashed replicas/pending work, and startup/readiness evidence. Inspect current runtime logs and ingestion/ranking activity where applicable. A successful image build alone is insufficient.
5. Probe the Development public readiness/API paths when available and verify signed-in/OAuth flows for runtime/auth changes. If a workspace proxy blocks public probes, report that limit and use Railway deployment health, replicas and logs as bounded platform evidence; do not claim public or authenticated user-flow verification.

Projection Pool and Coordinator use the Go indexing-worker host. Gateway, AppView, Operations, and Corpus Edge have separate Go executable and deployment gates; passing package tests does not establish that their hosted selectors or running deployments have changed.

For these API services, verify the actual process against the canonical disposable schema, including protected-route admission, internal trust, readiness recovery, cache isolation, and joined shutdown. Local Go AppView requires an explicit PostgreSQL `DATABASE_URL`; it does not provide the former service SQLite backend. Shared Swift libraries remain for the native app and source-based parity tests.

Production promotion starts from `main` and selects the backend changes after Development acceptance. Keep Development frontend changes and podcast enablement out of that candidate. Generate its schema-ready manifest and Go contract bundles from its own canonical migrations and schemas. Podcast PostgreSQL integration tests use `SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL`, enabled by CI only when both podcast migrations exist in the candidate; all other PostgreSQL checks remain enabled independently.

PR CI runs tests, static checks, contract comparisons, and disposable database migrations. Deployment Docker images and Next.js production bundles are built by the deployment pipeline, rather than duplicated in PR CI.

## Comments, names, and wiki publication

Authored source explains file purpose, exported contracts, side effects, time/size bounds, deterministic tie-breaks, ownership and failure behavior. Add phase comments where concurrency or transactional order carries an invariant; avoid restating every assignment. Variables name their domain role. Standard `t *testing.T`, discarded `_` bindings, and generic type parameters such as `T` are conventional exceptions; workload, decoder, candidate and authority variables should be descriptive.

Canonical public documentation lives in `docs/wiki/`. Home and sidebar index every page and the link checker validates internal double-bracket page links. `publish-wiki.yml` syncs only `main` to GitHub Wiki; it does not publish a Development branch or update Lichen. Lichen is a separate manual publication from these same canonical pages, preserving filenames/slugs and omitting `_Sidebar.md`. See [[Contributing]]. Source documentation on `dev` is reviewable before Production wiki publication; do not confuse checked-in pages with already-published public copies.
