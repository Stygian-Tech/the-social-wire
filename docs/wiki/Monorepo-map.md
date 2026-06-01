# Monorepo layout

Root folder name (clone path) may vary; structure matches [`the-social-wire`](https://github.com/Stygian-Tech/the-social-wire).

```
the-social-wire/
  apps/
    web/          # Next.js web client (Bun)
    apple/        # SwiftUI iOS/iPadOS
  services/
    gateway/          # OAuth, sync, PDS writes, AppView proxy (Fly.io)
    appview/          # Sidebar projection + Thin AppView reads (Fly.io)
    appview-worker/   # Jetstream ingestion (Fly.io)
  packages/
    lexicons/     # app.thesocialwire.* (and related) lexicons
    spec/         # OpenAPI for HTTP surfaces (/v1/appview, /v1/sync, …)
  supabase/
    migrations/   # Postgres (pds_repo_record_cache, content_items, read_marks, …)
  docs/
    architecture/ # narrative docs (overview, discovery, appview, lexicons)
    wiki/         # markdown synced to GitHub Wiki on push to main (publish-wiki.yml)
```

**Pointers**

- [Root README](https://github.com/Stygian-Tech/the-social-wire/blob/main/README.md)
- [[Thin-AppView]] — optional read index rollout
