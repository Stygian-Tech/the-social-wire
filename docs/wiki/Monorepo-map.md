# Monorepo layout

Root folder name (clone path) may vary; structure matches [`the-social-wire`](https://github.com/Stygian-Tech/the-social-wire).

```
the-social-wire/
  apps/
    web/          # Next.js web client (Bun)
    apple/        # SwiftUI iOS/iPadOS
  services/
    api/          # Swift / Hummingbird API package (`fly.toml`, Dockerfile)
  packages/
    lexicons/     # com.thesocialwire.* (and related) lexicons
    spec/         # OpenAPI for HTTP surfaces
  supabase/
    migrations/   # Postgres migrations (API cache; Actions: .github/workflows/supabase.yml)
  infra/
    docker/       # docker-compose — builds API from services/api + Caddy
  docs/
    architecture/ # narrative docs
    wiki/         # markdown synced to this GitHub Wiki (via Actions)
```

**Pointers**

- [Root README](https://github.com/Stygian-Tech/the-social-wire/blob/main/README.md)
