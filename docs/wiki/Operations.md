# Operations

The Social Wire has a dedicated, operator-only control plane rather than embedding administrative routes in the public reader service.

## Components

- **Operations Web** (`apps/operations`) is the Next.js console.
- **Operations service** (`services/operations`) owns environment-scoped evidence and control routes.
- **Gateway** verifies the operator's ATProto OAuth session and currently proxies `/v1/operations/*` over a private service origin. The checkout adds Lexicon-defined `app.thesocialwire.operations.*` XRPC aliases, but they are not deployed on the public gateways as of 2026-08-12.
- **Postgres** stores health, alerts, commands, audit records, events, metrics, traces, ingestion gaps, and backfill state.

Access is restricted by an environment-specific operator DID allowlist. The console does not switch between Development and Production at runtime.

## Console capabilities

- service health and dependency freshness;
- collection and ingestion status;
- Jetstream endpoint and reconnect evidence;
- AppView latency/error and Redis cache metrics;
- gap confirmation, investigation, and status changes;
- dry-run-first backfill creation and lifecycle controls;
- alerts, traces, commands, and a live event stream; and
- linked runbooks for recovery and stale-data diagnosis.

Backfill creation is dry-run-first. Mutations carry idempotency and expected-version evidence. Production additionally requires the exact `PRODUCTION` confirmation. Recovery and outbound alert delivery remain separately gated by environment variables.

## Jetstream and Charybdis

Charybdis consumes legacy Jetstream or projects the durable PostgreSQL inbox
populated by Jetstream V2 Ingest, polls Skyreader RSS subscriptions, and updates
the AppView index. The retired Tap transport remains represented in historical
evidence and recovery enums, but it is no longer a deployed service.

A bounded The Wire replay ends in `snapshot_complete`. Operations reports that as a healthy
terminal checkpoint without requiring a continuing intake lease, while still evaluating Charybdis
freshness, inbox backlog, dead letters, and recovery incidents independently.

## Runbooks

Canonical runbooks live in [`docs/runbooks/operations/`](https://github.com/Stygian-Tech/the-social-wire/tree/main/docs/runbooks/operations). Start with the [runbook index](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/runbooks/operations/README.md).

## Local console development

```bash
APP_ENV=dev NEXT_PUBLIC_OPERATIONS_DEMO_MODE=1 bun --cwd apps/operations dev
```

Demo mode is local-only and must never be enabled in a deployed console. A real local control-plane session requires a disposable Postgres database, matching Gateway/Operations secrets, OAuth metadata, and an operator DID allowlist.

Related: [[Deployment-and-environments]], [[Service-API]], [[Database]], [[Testing]].
