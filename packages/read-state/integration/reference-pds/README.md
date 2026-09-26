# Reference PDS Cleanup Conformance

Optional local integration fixture for the read-state garbage collector. It starts the official `@atproto/pds` server with its real SQLite repository store, plus the official PLC test server's in-memory database. All repository mutations use actual HTTP XRPC requests; transactions are never mocked.

From the repository root:

```sh
packages/read-state/integration/reference-pds/run.sh /tmp/read-state-pds-evidence
```

Requires Docker and approximately 1 GB of temporary space. The runner installs its separately locked dependencies in a disposable Node 22 container, then starts the test container with `--network none`, no published ports, no capabilities, a 2 GB memory ceiling, and a 90-second test deadline. The fixture refuses to run if any non-loopback interface exists. It creates only synthetic `.test` identities through the local PLC and has no SMTP configuration. No URL, account credential, or hosted service is accepted as input. Temporary server state and installed packages are removed on exit; output contains logs, source hashes, and JSON results.

This package is deliberately outside root workspace globs. Its PDS dependencies do not enter Web bundles, normal installs, or ordinary unit tests. The runner copies the current read-state core and Web CAR verifier without changing their source; `tsconfig.json` maps the browser Buffer import for Node execution. Source hashes identify precisely what was exercised.

The five scenarios cover:

- Cleanup's atomic singleton revision update and deletes invalidate a paused writer's old manifest CAS while preserving signed reachability for all three roots.
- A writer that wins first makes `swapCommit` reject the whole cleanup transaction; every chunk and the winning singleton remain intact.
- Replacing a candidate after its signed membership proof invalidates the cleanup commit before deletion.
- Replacing content at the same record key restarts the observed grace period.
- Losing the HTTP result after a real successful transaction, reconstructing the PDS from its persisted database, and reopening the on-disk cleanup journal recover from fresh signed proofs without repeating deletes.

The fixture uses a legacy session token and `validate: false` because these application lexicons are not registered in the isolated PDS. The unchanged application loaders still validate records, CIDs, signatures, and complete chains. This is a protocol transaction gate; it does **not** prove end-user OAuth/DPoP permissions, hosted AppView migration parity, browser behavior, or authenticated multi-device QA. Its confirmation callback verifies the current singleton CID only. Grace uses controlled wall and monotonic clocks; this is not a 24-hour retention soak. Garbage collection remains disabled in hosted environments.

Implementation references: [official TestPds](https://github.com/bluesky-social/atproto/blob/main/packages/dev-env/src/pds.ts), [official TestPlc](https://github.com/bluesky-social/atproto/blob/main/packages/dev-env/src/plc.ts), and [reference applyWrites](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/repo/applyWrites.ts). Versions and the Node image digest are pinned in this directory. Dependency upgrades require rerunning this fixture; source unit tests and the browser verifier tests remain separate checks.
