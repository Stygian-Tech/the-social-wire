# Synthetic Ranking Capacity Fixture

`WireRankingCapacityTests.swift` exercises the real PostgreSQL rollup refresh,
candidate query, ranker, generation commit, and edition projection over 5,000
invented stories and 25,000 invented share events. It is a separate capacity
experiment, not archive replay, observed popularity, or a production distribution.
It makes no HTTP requests. Its predefined synthetic moderation state allows all
fixture stories; production moderation behavior is not measured.

1. Export each exact baseline/candidate revision to a separate directory. Copy the
   fixture unchanged into `services/wire-worker/Tests/WireWorkerTests/` in each
   export. Do not copy it into a production source target.
2. Create a **fresh**, migrated `tsw92_bench_<12 lowercase hex digits>` database for
   each variant on a dedicated, otherwise idle PostgreSQL server. The driver only
   accepts a nondefault loopback port or a `tsw92-*.railway.internal` hostname, and
   refuses existing Wire data. Apply only that variant's intended migrations.
3. Set `WIRE_CAPACITY_DATABASE_URL`, `WIRE_CAPACITY_OUTPUT` (an absolute path that
   does not yet exist), and `WIRE_CAPACITY_REVISION` (the exact 40-character commit).
   Keep database credentials out of command output and evidence artifacts.
4. Run `swift test --filter WireRankingCapacityTests` from the exported worker
   package. Use an outer process deadline as well as the driver's 120-second
   cancellation deadline. The driver caps database plus WAL directory size at
   2 GiB, checks the cap before/after seeding and each cycle, and creates exactly
   5,000 candidates with five distinct baseline sharers per item.
5. Run variants sequentially with identical fixture bytes, fixed input time,
   machine resources, and the same three-cycle count. The first measured cycle
   is cold; all three durations are reported individually. Require 5,000 loaded,
   ranked, persisted, and rollup rows per cycle, plus 25,000 signal rows.
6. Once every test process has stopped, the enclosing harness drops only its
   newly created database. The fixture deliberately leaves cleanup to that owner.

JSON evidence includes an explicit synthetic disclaimer, revision, fixture
version, cardinalities, cycle durations, and before/after WAL counter epochs,
bytes, insertion LSNs, and database/WAL sizes. WAL statistics may flush after an
operation; the insertion-LSN delta is also included. Both WAL measures are
cluster-wide, so concurrent activity invalidates attribution. This experiment
does not measure ingestion, HTTP enrichment, request latency, scheduler cadence,
or a representative social graph. Apply observed savings only to the work it
actually exercises.
