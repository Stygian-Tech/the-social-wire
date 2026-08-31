# Railway infrastructure partial

`railway.ts` owns only the three consolidated indexing service classes in
Development and Production: Ingress Controller, Projection Pool, and
Coordinator. The stable partial name keeps omit-as-delete scoped to those
resources while the compatibility fleet remains on grandfathered
`railway/*.json` configuration during the rollback window. The graph aborts in
every other environment.

Development uses one AppView lane and one Wire lane. Production preserves the
live AppView lane plus independently fenced external and publication Wire lanes
inside the same replicated Ingress Controller. Production's Projection Pool is
co-located with Postgres and initially keeps the existing V1-V7 source scope;
widening it to V8 is a separate backlog/corpus decision.

The partial preserves database, Redis, API-key, HMAC, and migrator-reference
variables already present on each target service. It does not copy values from
compatibility services: seed the three targets before the first apply, then
`preserve()` retains those values without printing secrets into source.

Plan and apply from the repository root, explicitly linking the intended target:

```sh
railway environment link dev
railway config plan
railway config apply --yes
```

For Production, use `railway environment link production` only after the
protected `main` promotion, Database Migrator success, and target-variable seed
steps in the indexing consolidation runbook. Never apply a Development plan
artifact to Production.

Plans redact preserved database, Redis, and signing credentials. Never use
`--show-values` in shared logs.
