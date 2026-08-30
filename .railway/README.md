# Railway infrastructure partial

`railway.ts` owns only the three consolidated Development indexing services:
Ingress Controller, Projection Pool, and Coordinator. The stable partial name
keeps omit-as-delete scoped to those resources while the older service fleet
remains on grandfathered `railway/*.json` configuration during the transition.

The graph intentionally emits no Production resources. Enabling Production
requires a separately reviewed source change after the Development soak.

Plan and apply from the repository root:

```sh
railway environment link dev
railway config plan
railway config apply --yes
```

Plans redact preserved database, Redis, and signing credentials. Never use
`--show-values` in shared logs.
