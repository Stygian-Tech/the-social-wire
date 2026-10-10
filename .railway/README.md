# Railway infrastructure partial

`railway.ts` owns the three consolidated indexing service classes in
Development and Production: Ingress Controller, Projection Pool, and
Coordinator. Development additionally includes the Podcast Media bucket and
Podcast Media Worker through `podcasts.ts`; Production does not include or
enable these resources. The stable partial name keeps omit-as-delete scoped to
the resources owned by this graph while the compatibility fleet remains on grandfathered
`railway/*.json` configuration during the rollback window. The graph aborts in
every other environment.

Development uses the read-state AppView lane and the publication-west Wire lane.
Production preserves its AppView lane plus independently fenced external and
publication Wire lanes. The expired publication-west replay canary stays stopped;
its generation remains in the drain scope. Coordinator additionally retains the
three external snapshot generations for cleanup and recovery. Applying this
partial must not reset a cursor, reactivate the expired canary, or narrow either
scope.

Ingress pools explicitly allow eight open and one idle connection per lane, with
a 60-second idle timeout. Projection readiness uses its existing component pools;
Coordinator keeps isolated authority and diagnostic capacity. Compact ingestion
and selective rollups start disabled so each Development stage can be measured
separately. Enabling rollups requires both database tracking and the worker flag;
setting only one is not an activation. Operations retention catch-up is controlled
by `OPERATIONS_RETENTION_CATCHUP_ENABLED` on Ops, outside this partial.

The partial preserves database, Redis, API-key, HMAC, and migrator-reference
variables already present on each target service. It does not copy values from
compatibility services: seed the three targets before the first apply, then
`preserve()` retains those values without printing secrets into source.

Before applying Development podcast resources, seed the worker's Postgres URL,
migrator-service reference, shared media secret and dedicated bridge credentials.
The graph references the private bucket's endpoint, bucket name, region and keys.
It enables one worker replica in `sfo`, tracking `dev`, with the Development
Gateway as its public asset origin. Wait for Database Migrator success before
starting consumers; GitHub push deployment ordering does not follow variable
references. AppView's private worker URL and shared secret, and Web's build-time
feature flag, are configured separately. Do not expose a public worker domain.

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
