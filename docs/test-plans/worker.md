# Go indexing worker test plan

**Runtime:** `services/indexing-worker`, `packages/go/appviewworkercore`, `packages/go/wireworkercore`
**CI:** `indexing-worker`, `go-packages`

## Commands

```bash
(cd services/indexing-worker && go test -race ./... && go build ./cmd/indexing-worker)
(cd packages/go && go test -race -p 1 ./...)
```

PostgreSQL cases require canonically migrated disposable databases and explicit `SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL`, `SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL`, and topic/runtime-specific test variables. The Go CI gate provisions these databases; local tests skip integrations without explicit targets.

Coverage includes FIFO claim/apply/ack, lease renewal/takeover, stale authority rejection, repository recovery, cache invalidation, bounded telemetry, ranking/materialization, independent lane restart, standby readiness and joined shutdown. Durable Operations recovery retains diagnostic verification requirements.

## ThinAppViewCore

Retained Swift API/store contracts run in the `shared-swift` CI gate:

```bash
(cd packages/swift/ThinAppViewCore && swift test)
```

Tests retain render extraction, SQLite/Postgres indexing, RSS parser/identity, cache snapshots, pagination, read-state lifecycle, inbox SQL fencing and watermarks. `THIN_APPVIEW_TEST_DATABASE_URL` enables isolated PostgreSQL store tests. Worker transport/runtime tests are replaced by the Go conformance suite; retained shared API tests must continue to pass.

## Live acceptance

After exact-head CI and the exact Development deployment, verify both lane readiness, Coordinator ownership/standby, durable content projection and authenticated reader behavior. Use existing Gateway/AppView Bruno requests and the retained worker verification collection. A healthy listener alone is insufficient. Production promotion and rollback remain separate release actions.

- [AppView test plan](./appview.md)
- [Thin AppView architecture](../architecture/appview.md)
