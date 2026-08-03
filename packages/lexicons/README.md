# The Social Wire — ATProto Lexicons

This package contains the ATProto lexicon definitions for The Social Wire. These schemas define the record types that clients write to a user's PDS (Personal Data Server) to store their reading preferences.

## Design philosophy

The Social Wire stores **as little as possible** in its own infrastructure. The user's follow graph (`app.bsky.graph.follow`) already expresses intent — "I follow this person." We don't duplicate that.

The only data we write to the user's PDS is what the protocol doesn't already have:

| Lexicon | Purpose |
|---------|---------|
| `app.thesocialwire.folder` | A named folder for organizing publications |
| `app.thesocialwire.publicationPrefs` | Folder assignment, sort order, and visibility for a discovered publication |
| `app.thesocialwire.preferences` | Account-level Social Wire preferences; legacy provider fields remain compatible, while current clients always use L@tr Link |
| `link.latr.saved.external` | L@tr (latr.link) wrapper for normalized HTTPS URLs (read-later interoperability) |
| `link.latr.saved.item` | L@tr read-later queue item pointing at `subjectUri` (external wrapper or ATProto record) |
| `app.skyreader.feed.subscription` | RSS/Atom subscriptions (Skyreader-compatible) on the user's PDS; see [`app/skyreader/feed/subscription.json`](app/skyreader/feed/subscription.json) |

All records are public by default (ATProto repos are public). Any client that can read a PDS can see a user's Social Wire folders and preferences.

Feed read/unread state is not stored in ATProto repo records. Clients keep a local cache for immediate UI and write authenticated read marks to Social Wire AppView for unread filtering and counters.

### L@tr (read-later) compatibility

[L@tr / latr-link](https://tangled.org/samclemente.me/latr-link/) defines **`link.latr.saved.external`** and **`link.latr.saved.item`** (legacy **`com.latr.*`**) so read-later slots live entirely on the user’s PDS. The Social Wire **reads and writes** the same collections (deterministic keys and URL normalization aligned with upstream L@tr) so items saved here appear alongside other L@tr clients during OAuth-scoped **`com.atproto.repo.*`** access.

---

## Lexicons

### `app.thesocialwire.folder`

A named folder in the user's sidebar.

**Key:** `tid` (timestamp-based ID, auto-assigned by the PDS)

**Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string (max 128) | ✅ | Display name |
| `sortOrder` | integer | | Position in sidebar (lower = first) |
| `icon` | string (max 128) | | Emoji or icon name; UI falls back to a folder icon if omitted |
| `iconImage` | uri | | Custom image URI for the folder icon; takes precedence over `icon` |
| `createdAt` | datetime | ✅ | ISO 8601 creation timestamp |

**Example:**
```json
{
  "$type": "app.thesocialwire.folder",
  "name": "Tech",
  "sortOrder": 0,
  "icon": "💻",
  "createdAt": "2026-05-12T20:00:00.000Z"
}
```

---

### `app.thesocialwire.preferences`

Account-level preferences for The Social Wire. This record is keyed as `self`
and stores non-sensitive reader configuration. Its older read-later provider
fields remain schema-compatible, but current clients expose no provider selector
and always use L@tr Link for `/saved`.

Do not store third-party API tokens, passwords, refresh tokens, or secrets in
this record. ATProto repo records are public by default.

### `app.thesocialwire.publicationPrefs`

Organizational preferences for a discovered publication. The publication list itself comes from the user's follows — this record only stores what the protocol doesn't capture.

**Key:** `tid`

**Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `publicationId` | string | ✅ | at-uri or canonical URL of the publication |
| `folderId` | string | | rkey of the `app.thesocialwire.folder` record to assign this publication to |
| `sortOrder` | integer | | Position within the folder (or in "All Publications") |
| `hidden` | boolean | | If `true`, exclude from the sidebar |
| `createdAt` | datetime | ✅ | ISO 8601 creation timestamp |

**Example:**
```json
{
  "$type": "app.thesocialwire.publicationPrefs",
  "publicationId": "at://did:plc:abc123/com.example.publication/main",
  "folderId": "3jxxxxxxxxxxxx2",
  "sortOrder": 1,
  "hidden": false,
  "createdAt": "2026-05-12T20:00:00.000Z"
}
```

---

## Reading and writing records

Use the standard ATProto `com.atproto.repo.*` XRPC methods:

```ts
// List all folders for a user
await agent.api.com.atproto.repo.listRecords({
  repo: did,
  collection: "app.thesocialwire.folder",
});

// Create a folder
await agent.api.com.atproto.repo.putRecord({
  repo: did,
  collection: "app.thesocialwire.folder",
  rkey: TID.nextStr(),
  record: {
    $type: "app.thesocialwire.folder",
    name: "Tech",
    sortOrder: 0,
    createdAt: new Date().toISOString(),
  },
});

// Delete a folder
await agent.api.com.atproto.repo.deleteRecord({
  repo: did,
  collection: "app.thesocialwire.folder",
  rkey: folderRkey,
});
```

---

## Versioning policy

- Lexicon IDs are **stable**. Existing fields will not be removed or have their types changed.
- New **optional** fields may be added in minor revisions.
- Breaking changes require a new lexicon ID (e.g. `app.thesocialwire.folder#v2`).
- Material lexicon revisions are summarized in [CHANGELOG.md](./CHANGELOG.md).
