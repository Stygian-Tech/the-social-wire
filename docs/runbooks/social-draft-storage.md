# Private Social Draft Storage

Web draft text and native settings use Bluesky's private `app.bsky.draft` service.
Social Wire stores attachment files and their manifests in its own private service.
This is an explicitly approved exception to the rebuildable AppView projection
model: these files are canonical user data and cannot be rebuilt from the PDS.
Both services can read their stored data; this is not end-to-end encryption.

## Environment Rollout

The independent `.railway/social-drafts.ts` partial declares the Development
`Social Draft Attachments` bucket and the distinct Production
`Social Draft Attachments Production` bucket, both in `sjc`. Select the intended
environment when planning this file; do not apply the indexing partial as part
of a draft rollout. Existing provisioned buckets require no repeat apply.
App View remains managed by `railway/appview.json`.

Configure App View's server-only `SOCIAL_DRAFTS_ENABLED=true` and
`SOCIAL_DRAFT_STORAGE_KEY` (32 random bytes, standard base64), plus
`SOCIAL_DRAFT_S3_ENDPOINT`, `SOCIAL_DRAFT_S3_BUCKET`,
`SOCIAL_DRAFT_S3_ACCESS_KEY_ID`, `SOCIAL_DRAFT_S3_SECRET_ACCESS_KEY`, and
`SOCIAL_DRAFT_S3_REGION` using the dedicated bucket's Railway reference variables. Never reuse
podcast credentials or storage keys. Disabled storage returns unavailable; incomplete enabled configuration rejects
startup so a deployment cannot silently claim the feature is ready. No public bucket hostname, anonymous download, or signed public URL is used.

For Production, bind the five S3 variables to the Production bucket references,
set an independent Production storage key, and enable storage only after all
configuration is present. Keep configuration changes staged without deploying
until the approved source and migration are ready. Verify the database, key, and
bucket-byte backup and restore process together before enabling canonical writes;
never copy the Development key or bytes into Production.

The Database Migrator owns migration `20261020233000_private_social_draft_assets.sql`.
Deploy Gateway and App View with their existing migrator readiness dependency,
then Web. The four native draft RPC OAuth grants require renewed authorization
for older Web sessions. Verify the exact deployed commits, authenticated upload
and restoration in a fresh browser, owner isolation, and deletion retry before
acceptance. Merely rendering the Drafts page is insufficient.

## Storage and Recovery

Gateway authenticates every request. App View derives the owner from trusted
Gateway identity, encrypts binary files and sensitive metadata, and stores opaque
S3 keys. Downloads authenticate and verify the complete file before serving it
with `Cache-Control: private, no-store`. The Web client also verifies size, MIME
type and SHA-256 before restoring bytes. Draft saving never uploads to public PDS
blobs or posts/schedules a composition.

The limits are 100 MiB per file, 1 GiB of charged files per account and 10,000
charged assets. Original and prepared photos count separately. Reservations and
uploads use immutable client UUIDs; manifests use revision compare-and-swap.
Unbound uploads expire after 24 hours; referenced files have no automatic expiry.
Removing the last reference immediately revokes access and queues physical
deletion. Failed object deletion retries durably and continues charging quota.

Local recovery preserves interrupted work and uncertain native API operations.
The native API has no conditional update or idempotent create, so concurrent edits
require conflict copies rather than a claim of atomic cross-service transactions.
Failed file cleanup retains a completion/deletion marker and an explicit retry;
it must never cause a completed post to be published again.

## Canonical Data Operations

Back up the database manifests/metadata, private bucket contents, and encryption
key as one recoverable data set. A database restore alone does not recover files;
bucket bytes without their key cannot be decrypted. Keep the key in protected
operational secret storage. Do not replace or rotate the single configured key
without a migration that re-encrypts existing data. Never include it in logs,
support exports, source control, or browser configuration.

For an owner-requested export, enumerate that owner's native drafts and retrieve
their manifests and authenticated file downloads; treat the result as private
user content. Account erasure must remove the owner's manifest references and
queue all remaining assets through the durable cleanup path, then confirm physical
deletion before declaring completion. Ordinary projection rebuilds must exclude
all `private_social_draft_*` tables. Do not delete canonical rows ahead of object
cleanup. Draft deletion does not promise immediate erasure from backups or from
Bluesky's private operation history; apply the service's retention obligations to
backups separately.
