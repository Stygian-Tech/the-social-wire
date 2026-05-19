# Monorepo layout

Root folder name (clone path) may vary; structure matches [`the-social-wire`](https://github.com/Stygian-Tech/the-social-wire).

```
the-social-wire/
  apps/
    web/          # Next.js web client (Bun)
    apple/        # SwiftUI iOS/iPadOS
  services/
    api/          # Swift / Hummingbird gateway
                  #   fly.toml      → App serve (HTTP)
                  #   fly.worker.toml → App worker (Thin AppView ingest)
  packages/
    lexicons/     # com.thesocialwire.* (and related) lexicons
    spec/         # OpenAPI for HTTP surfaces (/v1/appview, /v1/sync, …)
  supabase/
    migrations/   # Postgres (pds_repo_record_cache, content_items, read_marks, …)
  infra/
    docker/       # docker-compose — builds API from services/api + Caddy
  docs/
    architecture/ # narrative docs (overview, discovery, appview, lexicons)
    wiki/         # markdown synced to GitHub Wiki on push to main (publish-wiki.yml)
```

**Pointers**

- [Root README](https://github.com/Stygian-Tech/the-social-wire/blob/main/README.md)
- [[Thin-AppView]] — optional read index rollout
