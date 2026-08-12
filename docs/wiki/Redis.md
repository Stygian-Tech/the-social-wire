# Redis

Social Wire uses private Railway Redis as an optional, disposable cache and coordination layer for hosted Gateway, AppView, and Charybdis. Authoritative PDS records remain on user/author PDSes; durable and rebuildable source/index, read, RSS metadata, ingestion, repair, and Operations state remain in Postgres.

Redis provides stale-first sidebar/unread/first-page caches, Gateway PDS-record caching, shared PLC resolution, distributed rebuild and RSS leases, reusable sorted-set ranking primitives, and bounded Operations metrics. Keys hash every DID, URL, and AT-URI with full SHA-256. Redis failure is a cache miss and never a durable-write or readiness failure.

Development is provisioned and soaked first. Production receives no Redis infrastructure or backend-flag changes until Development evidence is reviewed and explicitly approved. Postgres cache tables remain temporarily for rollback but receive no reads or writes while Redis mode is selected.

Canonical design, policies, configuration, drills, and rollback: [docs/architecture/redis.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/redis.md).
