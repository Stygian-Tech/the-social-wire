# Go ingestion and ranking migration

The Go migration adds a repository-local shared module at `packages/go`, with counterparts for every shared package in the source inventory and an initial `wireworkercore` library. It is **in progress**. Ingress already uses Go; Projection Pool, Coordinator, Gateway, and AppView still retain their existing runtime implementations. Deploying this foundation does not switch those workers to Go.

[[Go-package-reference]] explains every authored source file, caller responsibility, and package boundary. [[Go-verification-and-deployment]] covers tooling, test evidence, CI, deployment, and completion criteria.

## Module and ownership

Services import `github.com/stygian-tech/the-social-wire/packages/go/<package>` and resolve it through a repository-local `replace ... => ../../packages/go`. Use `GOWORK=off`; no published module or separate repository is required. Go 1.26 is pinned through the ingestion toolchain. Dependencies are pinned in `packages/go/go.mod` and `go.sum`.

| Layer | Packages | Responsibility |
| --- | --- | --- |
| Pure domain rules | `wirecore`, `financecore`, `sportscore`, `readstatecore` | Ranking, serving shapes, identities, projection and hashing with explicit inputs. |
| Ingestion decoding | `thinappviewcore` | Jetstream envelope validation and RSS/Atom/JSON Feed translation; no durable event application yet. |
| Infrastructure | `operationscore`, `socialwireredis`, `gatewaycore` | Fenced ownership, disposable caches, token inspection and DNS admission helpers. |
| Contract data/facade | `lexicons`, `spec`, `readstate` | Canonical schema/API access and aliases of implemented read-state surfaces. |
| Background library | `wireworkercore` | Candidate snapshots, ranking cycles, atomic generation publication and retention; no worker host yet. |
| Internal/verification | `internal/signedcursor`, `cmd/*-parity` | Authenticated cursor envelopes and test-only stdin/stdout oracle bridges. |

Postgres stores rebuildable server projections. PDS records remain canonical for user-authored data. Redis remains disposable and optional. The migration does not change those ownership boundaries; see [[Architecture]], [[Database]], [[Redis]], and [[Thin-AppView]].

## Upstream libraries used directly

| Concern | Library | Repository responsibility retained |
| --- | --- | --- |
| Feed parsing | `github.com/mmcdole/gofeed` | Serving field translation, date fallback, image precedence and deterministic ordering. |
| HTML | `golang.org/x/net/html` | Thumbnail selection and normalization; caller controls fetching. |
| Redis | `github.com/redis/go-redis/v9` | Swift-compatible envelopes, namespaces and service-owned TLS/deadlines/pools. |
| Circuit state | `github.com/sony/gobreaker/v2` | Three failures, five-second cooldown, one recovery probe, cancellation exclusion. |
| Canonical encoding | `github.com/ipld/go-ipld-prime` | Restricted receipt values, safe integers, bounds, domain-separated hashes. |
| Compact JWS | `github.com/go-jose/go-jose/v4` | Inspection only. No signature, issuer, audience or DPoP authentication result. |
| Jetstream | `github.com/bluesky-social/jetstream` | Stored metadata equality, exact integers, lifecycle/record validation. |
| OpenAPI | `github.com/pb33f/libopenapi` | Canonical source embedding, digest and route/model drift checks. |
| PostgreSQL | `github.com/jackc/pgx/v5` | Canonical schema queries, transaction/authority rules and connection budgets. |
| Unicode | `golang.org/x/text` | Domain-specific normalization and stable preference/entity identity. |

`miniredis` is a test dependency for transport round trips and TTLs. Upstream implementations replace generic protocol machinery while repository code retains domain contracts. Exact versions belong in the module manifest so this page cannot become a competing dependency lockfile.

Library adoption intentionally corrects fractional feed-date handling, offset-aware chronological sorting, JSON Feed support, comment/script thumbnail matches, and circuit completions from stale generations. It retains shared canonical receipt/intent hashes and exact Jetstream record integers. These fixes are tested rather than described as byte-for-byte parser parity.

## Ranking and publication flow

1. The host acquires a role lease and carries its environment/role/owner/fencing token into protected writes. Separate connection capacity keeps control operations from being starved by workload queries.
2. `Cycle.Run` validates configuration and pings its store. Off stops there. Enabled cycles optionally maintain inboxes, clean bounded retention, and require a successful baseline-label refresh before candidate loading.
3. The cycle chooses baseline/external plans and discovers up to twelve eligible non-global languages when starting with `und`. Candidate reads exclude expired, ineligible, blocked and probable-ad items, preserve metadata admission, and select the matching baseline/external rollups.
4. Wire ranking applies age/quality/signal admission, normalized signal weights, negative feedback and presentation/commercial/domain penalties, deterministic rotation, stable key tie-breaks, bounded backfill, and first-page diversity.
5. A generation commit locks the feed/language pointer, writes ranks, materializes the ordinary and outside-US edition variants, and includes account highlights in one transaction. Regional module keys use an `outside-us:` prefix and a separate ordinal range.
6. Immediately before publication, the transaction locks and checks role authority against current database time. Activation requires authority and serving floors; superseding the old generation and moving the pointer happen atomically. Shadow commits leave the pointer unchanged. Any error rolls back that generation’s rows and pointer writes.
7. Local scheduling uses unique reservation tokens to reject stale completions. Successful cadence and readiness age use cycle start time; a failure clears readiness and retries in one minute. This scheduler does not replace distributed leases.

A cycle can contain multiple independently atomic generation commits. A later language/plan failure does **not** roll back earlier commits. Retention likewise commits bounded statements separately; retries can resume partial cleanup. Inactive expired generations are removable, while active generations are preserved even after expiry.

## Compatibility rules worth preserving

- Ranking uses explicit clocks, stable keys and deterministic accumulation order. Wire scores compare with absolute tolerance `1e-12`; reasons, ordering and diagnostics compare exactly.
- Finance and Sports suppress duplicate identity/URL/coverage but intentionally retain their respective Swift identity-reservation order. Optional every-fifth global slots are selected from remaining eligible candidates.
- Sports requires current resolver evidence, direct confidence at least 0.9, and explicit personal mute precedence. A personal follow overrides only broader mutes. Membership intervals include start and exclude end; legacy numeric timestamps use Swift’s 2001 epoch.
- Edition allocation avoids repeating stories across lead/panels/rails/general. Trending is a separate view and may repeat stories. Lead stories prefer distinct domains and can admit a standard.site story from the top ten. Panels require two stories; reason rails require four. Profile highlights require two stories and three speakers.
- Canonical article URLs remove known tracking data while retaining semantic query fields and literal plus signs. Normalization and classification do not authorize network access.
- Read-state projection selects the greatest applicable sequence across exact subjects and scoped boundaries. JSON omission distinctions matter. Hashing uses restricted DAG-CBOR values, not ordinary JSON serialization order. Device acknowledgements must reproduce a contiguous pending-intent prefix.
- Wire cursors authenticate generation/language/ordinal but have no intrinsic expiry. Circle additionally checks a secret-derived viewer binding, snapshot, and expiry. Signed JSON is readable, not encrypted.
- Corpus request verification binds the complete target, method, expected service, nonce, timestamp, and optional body digest, with a ±60-second window. The receiver must separately compare the body bytes and prevent nonce replay.
- Gateway JWT payload inspection is **not authentication**. DNS admission must be coupled to pinned-address dialing and redirect revalidation. RSS decoding does not fetch or apply durable records.

## Completion tracking

`packages/go/migration/source-inventory.json` records canonical source contracts and digests. `migration/status.json` separately records implemented surfaces, outstanding work and verification. Neither a target directory nor a refreshed digest is proof of parity.

Pending work includes Go Projection Pool event application/repair/drain, Coordinator jobs/enrichment/labels/graph maintenance, Finance/Sports resolvers/catalogs/providers/projectors, Operations telemetry/store compatibility, strict read-state v2 loading/merge/compaction/sync/stores, typed Lexicon validation, authenticated Gateway adapters, specialized Redis clients, podcast parsing/listener/store surfaces, and runnable replacement worker/deployment targets. Preserve these gaps when reporting migration progress.

Related: [[Go-package-reference]], [[Go-verification-and-deployment]], [[Monorepo-map]], [[Testing]], [[Deployment-and-environments]].
