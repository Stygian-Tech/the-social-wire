# Railway infrastructure partial

`railway.ts` owns only the three consolidated Development indexing services:
Ingress Controller, Projection Pool, and Coordinator. The stable partial name
keeps omit-as-delete scoped to those resources while the older service fleet
remains on grandfathered `railway/*.json` configuration during the transition.

The graph aborts outside Development. Enabling Production requires a separately
reviewed source change after the Development soak.

The partial preserves database, Redis, API-key, HMAC, and migrator-reference
variables already present on each target service. It does not copy values from
compatibility services: seed the three targets before the first apply, then
`preserve()` retains those values without printing secrets into source.

Plan and apply from the repository root:

```sh
railway environment link dev
railway config plan
railway config apply --yes
```

Plans redact preserved database, Redis, and signing credentials. Never use
`--show-values` in shared logs.
