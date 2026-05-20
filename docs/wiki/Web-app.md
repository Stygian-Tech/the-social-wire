# Web app

Next.js client under `apps/web`.

**Setup and internals**

- [apps/web/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/README.md)

Includes ATProto OAuth (hosted vs loopback dev), PDS vs Bluesky App View usage, env vars, and testing commands.

## Data sources

| Data | Default path | Optional Thin AppView |
|------|--------------|------------------------|
| Folders, prefs, read state writes | User PDS (`pdsClient`) | PDS canonical; read marks write-through to gateway |
| Publication discovery | PDS + `public.api.bsky.app` follows | Enrollment calls gateway after discovery |
| Entry **lists** | Author PDS `listRecords` | `thinAppViewClient` → `GET /v1/appview/entries` |
| Entry **detail** | Author PDS `getRecord` | Always PDS (unchanged) |

## Thin AppView (optional)

Enable when the gateway worker is deployed and Supabase migration is applied:

```bash
# apps/web/.env.local
NEXT_PUBLIC_USE_THIN_APPVIEW=true
NEXT_PUBLIC_SOCIALWIRE_API_URL=https://api.thesocialwire.app
```

| Module | Role |
|--------|------|
| `src/lib/thinAppViewClient.ts` | Gateway client via OAuth `fetchHandler` |
| `src/hooks/useEntries.ts` | Routes list fetch to AppView when flag on |
| `src/lib/pdsClient.ts` | Write-through read marks after PDS success |
| `src/hooks/usePublications.ts` | `POST /v1/appview/enroll` after discovery |

Local optimistic read state (`the-social-wire.read-state.v1`) remains primary for UI; the index enables server-side unread pagination.

See [[Thin-AppView]].

## Testing

Unit tests: `cd apps/web && bun test` (CI: `build-web`).

| Area | Coverage |
|------|----------|
| `src/lib/` | All modules — see [test plan](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/test-plans/web.md) |
| `src/hooks/` | Priority hooks (entries, sidebar, read-later, publications) |
| `src/app/api/` | Route handler tests |
| `src/components/` | Manual browser verification only |

See [[Testing]].

## Related

- Example env: [apps/web/.env.example](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/.env.example)
- Hosted OAuth metadata: [client-metadata.json](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/public/client-metadata.json)
- [[Service-API]] — gateway routes and deployment
