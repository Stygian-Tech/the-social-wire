# ATProto Lexicons

The Social Wire uses two custom ATProto lexicons for storing user data. Both lexicons are public — any ATProto client can read a user's Social Wire records.

## `com.thesocialwire.folder`

A named group for organising publication subscriptions.

```json
{
  "lexicon": 1,
  "id": "com.thesocialwire.folder",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "required": ["name", "createdAt"],
        "properties": {
          "name":      { "type": "string", "maxLength": 128 },
          "sortOrder": { "type": "integer", "default": 0 },
          "icon":      { "type": "string", "maxLength": 128, "description": "emoji or short icon name" },
          "iconImage": { "type": "string", "format": "uri", "description": "optional custom image URL" },
          "createdAt": { "type": "string", "format": "datetime" }
        }
      }
    }
  }
}
```

### Design decisions

- `icon` allows an emoji or a short icon name (e.g. `"💻"` or `"tech"`). Clients choose how to render it; the default is a folder SVG.
- `iconImage` is an optional image URL for custom folder icons (Phase 1b feature). Clients fall back to `icon` if not present.
- `sortOrder` controls the order in the sidebar; clients assign sequential integers.

## `com.thesocialwire.publicationPrefs`

User display preferences for a discovered publication.

The publication list itself is derived from `app.bsky.graph.follow` records (already in the protocol). This record only stores what isn't in the protocol: folder placement and display flags.

```json
{
  "lexicon": 1,
  "id": "com.thesocialwire.publicationPrefs",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "required": ["publicationId", "createdAt"],
        "properties": {
          "publicationId": { "type": "string", "description": "at-uri or canonical URL of the publication" },
          "folderId":      { "type": "string", "description": "rkey of the com.thesocialwire.folder record" },
          "sortOrder":     { "type": "integer", "default": 0 },
          "hidden":        { "type": "boolean", "default": false },
          "createdAt":     { "type": "string", "format": "datetime" }
        }
      }
    }
  }
}
```

### Design decisions

- Publications with **no `publicationPrefs` record** appear in "All Publications" (uncategorised, visible by default).
- **No subscription record** is needed — following an account via `app.bsky.graph.follow` already expresses "I want to read this person." This avoids duplicating intent.
- `hidden: true` lets users hide a publication from the sidebar without unfollowing.

## Reading records via the ATProto API

Any ATProto client can list a user's Social Wire records:

```http
GET https://{pds-host}/xrpc/com.atproto.repo.listRecords
  ?repo={did}
  &collection=com.thesocialwire.folder
  &limit=100
```

This demonstrates the interoperability principle — no Social Wire-specific API is needed to read user preferences.

## Versioning

Lexicons follow the ATProto versioning convention:
- Breaking changes require a new lexicon ID (e.g. `com.thesocialwire.folderV2`)
- Non-breaking additions (new optional fields) can be added to the existing ID
- The `$type` field in records always reflects the current lexicon ID
