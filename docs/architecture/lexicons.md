# ATProto Lexicons

The Social Wire keeps portable, user-authored state on the viewer's ATProto PDS. The canonical JSON schemas tracked in this repository live under [`packages/lexicons/`](../../packages/lexicons/).

## Tracked schemas

| Collection | Purpose |
|------------|---------|
| `app.thesocialwire.folder` | Named publication folder with order and optional icon fields |
| `app.thesocialwire.publicationPrefs` | Per-publication folder assignment and ordering |
| `app.thesocialwire.preferences` | Account-level, non-secret Social Wire preferences |
| `app.skyreader.feed.subscription` | Skyreader-compatible RSS/Atom subscription |
| `community.lexicon.bookmarks.bookmark` | Authoritative generic bookmark subject, timestamp, and tags |
| `link.latr.bookmarks.metadata` | L@tr archive state, note, and last-opened metadata |

The clients also interoperate with externally defined collections such as `site.standard.graph.subscription`; that schema is not redefined in `packages/lexicons`.

Feed read/unread state is not an ATProto repo collection in the current product. Clients keep an immediate local cache and write authenticated read marks and scoped read floors to Social Wire AppView.

## Ownership and privacy

ATProto repo records are public by default. Folder names, publication preferences, subscriptions, bookmarks, and L@tr metadata must not contain passwords, API keys, refresh tokens, or other secrets. Social Wire's derived AppView rows can be rebuilt; the viewer PDS remains authoritative for user-authored records.

## Reading and writing records

Clients use standard `com.atproto.repo.*` XRPC methods with an OAuth session bound to the viewer PDS:

```http
GET https://{pds-host}/xrpc/com.atproto.repo.listRecords
  ?repo={did}
  &collection=app.thesocialwire.folder
  &limit=100
```

Web and iOS write user-authored records directly to the PDS with a PDS-bound OAuth session and DPoP proof.

## Versioning

- Existing lexicon IDs and field types remain stable.
- Compatible revisions add optional fields.
- Breaking changes require a new lexicon ID.
- L@tr XRPC and metadata schemas are drift-tested against the immutable `latr-packages` revision.

See the [package reference](../../packages/lexicons/README.md) for field tables, examples, test commands, and the versioning policy.
