# The Wire Corpus Edge

The Wire Corpus Edge is the sole cross-environment presentation boundary for **The Wire** — **Important stories across the social web**. It runs only in Production, reads the canonical Production PostgreSQL corpus over Railway private networking, and exposes a small authenticated HTTPS API to Development AppView. Production AppView continues to use its local `PostgresWireFeedStore`; it never calls the public edge.

It never accepts viewer access tokens, DPoP proofs, cookies, viewer DIDs, or Gateway/AppView trust headers. It never returns ranking scores, diagnostics, counts, raw labels, signals, actor hashes, graph state, inbox rows, or Operations/viewer data. Baseline-label freshness and presentation exclusions are enforced before every corpus response. Responses use `Cache-Control: no-store` and intentionally provide no CORS policy.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `APP_ENV` | required `prod` | Prevents accidental non-Production corpus ownership |
| `DATABASE_URL` | required | Production private PostgreSQL URL; never a cross-environment public database URL |
| `WIRE_CORPUS_EDGE_SHARED_SECRET` | required | Dedicated 32-byte-minimum HMAC secret, unrelated to Gateway/AppView trust |
| `WIRE_CORPUS_EDGE_ALLOWED_SERVICE_ID` | required | Development AppView identity bound to the independently rotatable secret |
| `WIRE_CORPUS_EDGE_POSTGRES_MAX_CONNECTIONS` | `4` | Bounded pool, clamped to `2...8` |
| `PORT` | `8080` | HTTP listen port |

The signed request covers the service ID, timestamp, one-time UUID nonce, method, path, and exact query. The edge accepts at most 10,000 unexpired nonces and fails closed on replay or capacity exhaustion. Query keys are allowlisted and duplicates are rejected.

Development AppView uses:

- `WIRE_CORPUS_EDGE_BASE_URL=https://...`
- `WIRE_CORPUS_EDGE_SERVICE_ID=<matching identity>`
- `WIRE_CORPUS_EDGE_HMAC_SECRET=<matching dedicated secret>`
- its own `WIRE_CURSOR_HMAC_SECRET`

AppView applies viewer block, mute, and muted-word filtering locally and signs its own public cursor. Runtime edge failure makes only The Wire unavailable; AppView readiness and Subscribed/Following remain tied to the Development database.

The provider-neutral `wire_serving` views are installed by the Database Migrator. Production role creation and grants are operator-owned: the edge login should have `SELECT` only on `wire_serving`, `default_transaction_read_only=on`, bounded connections, and no raw-table or mutation privileges.
