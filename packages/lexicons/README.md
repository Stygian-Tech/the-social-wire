# The Social Wire — ATProto Lexicons

This package contains the ATProto lexicon definitions for The Social Wire. These schemas define the record types that clients write to a user's PDS (Personal Data Server) to store their reading preferences.

## Design philosophy

The Social Wire stores **as little as possible** in its own infrastructure. The user's follow graph (`app.bsky.graph.follow`) already expresses intent — "I follow this person." We don't duplicate that.

The only data we write to the user's PDS is what the protocol doesn't already have:

| Lexicon | Purpose |
|---------|---------|
| `com.thesocialwire.folder` | A named folder for organizing publications |
| `com.thesocialwire.publicationPrefs` | Folder assignment, sort order, and visibility for a discovered publication |

All records are public by default (ATProto repos are public). Any client that can read a PDS can see a user's Social Wire folders and preferences.

---

## Lexicons

### `com.thesocialwire.folder`

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
  "$type": "com.thesocialwire.folder",
  "name": "Tech",
  "sortOrder": 0,
  "icon": "💻",
  "createdAt": "2026-05-12T20:00:00.000Z"
}
```

---

### `com.thesocialwire.publicationPrefs`

Organizational preferences for a discovered publication. The publication list itself comes from the user's follows — this record only stores what the protocol doesn't capture.

**Key:** `tid`

**Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `publicationId` | string | ✅ | at-uri or canonical URL of the publication |
| `folderId` | string | | rkey of the `com.thesocialwire.folder` record to assign this publication to |
| `sortOrder` | integer | | Position within the folder (or in "All Publications") |
| `hidden` | boolean | | If `true`, exclude from the sidebar |
| `createdAt` | datetime | ✅ | ISO 8601 creation timestamp |

**Example:**
```json
{
  "$type": "com.thesocialwire.publicationPrefs",
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
  collection: "com.thesocialwire.folder",
});

// Create a folder
await agent.api.com.atproto.repo.putRecord({
  repo: did,
  collection: "com.thesocialwire.folder",
  rkey: TID.nextStr(),
  record: {
    $type: "com.thesocialwire.folder",
    name: "Tech",
    sortOrder: 0,
    createdAt: new Date().toISOString(),
  },
});

// Delete a folder
await agent.api.com.atproto.repo.deleteRecord({
  repo: did,
  collection: "com.thesocialwire.folder",
  rkey: folderRkey,
});
```

---

## Versioning policy

- Lexicon IDs are **stable**. Existing fields will not be removed or have their types changed.
- New **optional** fields may be added in minor revisions.
- Breaking changes require a new lexicon ID (e.g. `com.thesocialwire.folder#v2`).
- All changes are documented in [CHANGELOG.md](./CHANGELOG.md) (to be created when first revision ships).
