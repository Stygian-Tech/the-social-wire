# Private social draft attachments

`New` requires an enabled configuration, a PostgreSQL connection, an HTTPS S3
endpoint and dedicated bucket credentials, and a standard-base64 encoded 32-byte
storage key. Missing or malformed configuration returns `ErrUnavailable`. The
caller supplies an authenticated, trusted owner DID; this package never derives
identity from attachment IDs. It does not publish PDS records or public URLs.

Reserve a client UUID, upload its exact declared bytes, then bind ready assets to
a native-TID draft using revision CAS (zero creates). Identical reservations and
uploads are idempotent. An asset UUID is immutable within its owner namespace,
including after deletion. Reserving a deleted or purged ID returns
`ErrAssetRetired`, which wraps `ErrConflict` for `errors.Is` compatibility. Active
metadata mismatches and manifest CAS failures remain `ErrConflict`. Route handlers
must check `ErrAssetRetired` first and map it to `AssetRetired` (HTTP 409).
Shared references across that owner's drafts are allowed. Missing manifests return `ErrNotFound`; deleted manifests remain readable
as empty tombstones with a monotonically increasing revision. A caller can restore
a tombstone only using its current revision.

Files use version 1 binary AES-256-GCM frames: a `TSWDA` + `0x01` header followed
by big-endian uint32 frame lengths and nonce-prefixed ciphertext frames. Plaintext
frames are at most 64 KiB. Every frame authenticates JSON-encoded domain, version,
owner, asset ID, and frame index; an authenticated empty final frame prevents
truncation. Metadata uses a separate authenticated domain. Random nonces and
opaque random object keys disclose neither filenames nor owner IDs to S3.
Downloads authenticate the entire object and verify SHA-256 into a private
0600 temporary file before returning it; callers must close the returned reader.
Uploads use bounded private temporary files, never whole-file memory buffers.

Before obtaining a database connection, per-instance admission rejects concurrent
operations for an already active owner and caps total operations at eight (or one
quarter of a bounded DB pool, minimum one). Overload returns `ErrUnavailable`;
cancelled contexts return their cancellation error. No admission waiters retain
connections or temporary files. Across replicas, owner row locks use `NOWAIT` and
inserts have a 100 ms lock timeout, also returning `ErrUnavailable` on contention.

Uploads read immutable metadata with one short query, then receive, validate and
encrypt the bounded temporary file before starting a transaction. Finalization
rechecks the asset's state, immutable metadata and object key under the owner lock.
The lock remains held through the local-file S3 PUT and ready commit, preventing
cleanup or deletion from racing a stale upload into resurrecting an object.
Owner locks also serialize quota, manifests and cleanup. Callers should supply
request deadlines for body and object I/O. No global DB lock spans owners.

Removing a final draft reference immediately revokes an asset and queues physical
deletion. Staged unreferenced assets expire after 24 hours from reservation.
Referenced assets have no scheduled cleanup job and never expire; final detach
recreates an immediate job. Pending deletions continue charging both the 1 GiB
byte quota and a 10,000 charged-asset limit until S3 confirms deletion. Only then
is an asset marked internally purged and its sensitive metadata erased; its ID
remains an immutable tombstone. This bounds tiny-asset and failed-deletion backlogs.

`Cleanup(ctx, limit)` processes at most `limit` (1–1000) due entries in oldest due
time order, claiming owner and outbox rows with database locks and `SKIP LOCKED`.
Failed deletes do not stop the bounded batch from processing other due jobs; it
returns `ErrUnavailable` after retaining retries. Delete failures retain a durable
outbox record with exponential retry (one minute to one hour). Each object delete
is bounded by five seconds, half the remaining sweep budget, and the job deadline
minus a two-second persistence reserve, whichever is shortest. Transactions have
an independent seven-second maximum lifetime; final state/backoff persistence has
an independent two-second budget, including cancellation of a blocked commit.
Sweep cancellation during S3 I/O therefore does not discard the retry update.
Later due jobs proceed when sweep budget remains. A crash after S3 deletion safely repeats that
idempotent deletion. Deleted identity rows remain to prevent UUID reuse.

Run unit tests with `go test ./socialdraftcore`. PostgreSQL tests create and drop
an isolated schema when `SOCIALWIRE_GO_TEST_DATABASE_URL` is set; the connection
must allow schema creation. Use `go test -race ./socialdraftcore` for quota, CAS,
and concurrent cleanup coverage. Tests use a fake object store and a local TLS S3
fixture, without hosted infrastructure.
