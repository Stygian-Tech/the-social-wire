# Contributing

How to work in the monorepo and open pull requests.

**Full guide:** [CONTRIBUTING.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/CONTRIBUTING.md)

## Clone and setup

```bash
git clone https://github.com/Stygian-Tech/the-social-wire.git
cd the-social-wire
bun install
```

## Pick your surface

| Area | Setup doc |
|------|-----------|
| Web | [apps/web/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/web/README.md) |
| API | [services/api/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/services/api/README.md) |
| iOS | [apps/apple/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/apps/apple/README.md) |
| Worker | [services/worker/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/services/worker/README.md) |

## Tests before PR

Run tests for packages you changed. See [[Testing]] for commands and checklists.

## Wiki edits

Edit pages under **`docs/wiki/`** only. GitHub Wiki is synced from `main` via `publish-wiki.yml` — do not edit the GitHub Wiki UI directly.

## Related

- [[Testing]]
- [[Monorepo-map]]
