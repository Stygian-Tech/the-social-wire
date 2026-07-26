# Tap synchronization service

This service packages Bluesky's Tap at the pinned Indigo commit in `Dockerfile`. It runs in
acknowledgement mode, uses a dynamically managed repository boundary, and only requests registered
Social Wire content collections. It is private-network infrastructure; the AppView worker connects through
the environment-specific `*.internal` hostname.

Tap authority is deliberately limited to `site.standard.document` and `site.standard.entry` until
subscription, graph, and read-state mutations have their own durable parity and projection-repair
contracts. Those collections are not included in Tap's configured coverage and must never be counted
toward a 100% shadow-parity claim.

Required Fly secrets, set independently on each Tap app:

- `TAP_DATABASE_URL`: an environment-isolated PostgreSQL database URL owned by Tap.
- `TAP_ADMIN_PASSWORD`: a unique random password used for `/channel` and `/repos/*` Basic auth.

Set the same `TAP_ADMIN_PASSWORD` on the matching AppView worker. The worker uses:

- `TAP_CONSUMER_MODE=shadow` during parity burn-in. `authoritative` is a guarded cutover mode.
- `TAP_BASE_URL=http://the-social-wire-{dev|prod}-tap.internal:2480`.
- `APP_ENV=dev|prod`, which is part of every durable Tap repository-state key.

Do not set `TAP_DISABLE_ACKS=true` outside an isolated local inspection run. Do not use
`TAP_FULL_NETWORK`; repositories are added through `/repos/add` as AppView enrolls them.
Because the admin password protects every HTTP route, Fly uses a TCP liveness check. Readiness and
repository-sync health must come from the authenticated Tap capability and worker evidence, not an
unauthenticated `/health` response.
