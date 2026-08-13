# Lexicons

ATProto lexicon JSON under `packages/lexicons` defines portable Social Wire
preferences, read-later interoperability (`link.latr.*`; legacy `com.latr.*`
compatibility), Skyreader subscriptions, and the Lexicon-defined XRPC contract
for Social Wire services.

**Reference**

- [packages/lexicons/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/README.md)
- [CHANGELOG](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/CHANGELOG.md)

Related architecture notes: [docs/architecture/lexicons.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md).

## Tracked collections

| Collection | Purpose |
|------------|---------|
| `app.thesocialwire.folder` | Named publication folders |
| `app.thesocialwire.publicationPrefs` | Folder assignment and ordering |
| `app.thesocialwire.preferences` | Non-secret reader preferences |
| `app.skyreader.feed.subscription` | RSS/Atom subscriptions |
| `link.latr.saved.external` | Normalized external-link wrapper |
| `link.latr.saved.item` | L@tr queue item and state |

The clients also interoperate with externally defined `site.standard.graph.subscription` records; that schema is not redefined here.

Feed read/unread state is not a tracked Social Wire lexicon. Current clients keep a local cache for immediate UI and write authenticated read marks and scoped read boundaries to [[Thin-AppView]]. OAuth tests explicitly exclude the historical `app.thesocialwire.entryReadState` and `com.thesocialwire.entryReadState` collections.

## Service XRPC Lexicons

Lexicons under `packages/lexicons/app/thesocialwire/` describe authenticated
queries and procedures in four namespaces:

| Namespace | Examples |
|-----------|----------|
| `app.thesocialwire.sync.*` | preference synchronization |
| `app.thesocialwire.publication.*` | sidebar reads, refresh, and publication resolution |
| `app.thesocialwire.appview.*` | feeds, entries, unread state, enrollment, and viewer-data purge |
| `app.thesocialwire.operations.*` | operator evidence and controlled recovery actions |

These describe service methods intended for `/xrpc/{NSID}`; they are not records
stored in a user's repository. The migration is implemented in the current
checkout but is not registered on the public Testing or Production gateways as
of 2026-08-12. The checked-in
[`endpoint-manifest.json`](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/spec/endpoint-manifest.json)
maps each compatible `/v1/*` operation to its NSID and explicitly classifies the
HTTP surfaces that remain outside XRPC.

ATProto repo records are public by default. Folder names, preferences, subscriptions, saved-item metadata, notes, and tags must not contain passwords, tokens, or other secrets.
