# Contributing

Thank you for contributing to The Social Wire.

## Getting started

1. Clone the repo and install dependencies: `bun install`
2. Pick the surface you are changing — see [docs/test-plans/README.md](docs/test-plans/README.md)
3. Copy the relevant `.env.example` to `.env` / `.env.local`
4. Run tests for affected packages before opening a PR

## Where tests live

Tests must live **inside the owning package**, not in a root-level `tests/` folder:

| Package | Test location |
|---------|---------------|
| Web | `apps/web/src/__tests__/` |
| Operations UI | colocated `*.test.ts` / `*.test.tsx` under `apps/operations/src/` |
| Gateway | `services/gateway/Tests/` |
| AppView | `services/appview/Tests/` |
| Charybdis | `services/appview-worker/Tests/` |
| Operations service | `services/operations/Tests/` |
| GatewayCore | `packages/swift/GatewayCore/Tests/` |
| SocialWireRedis | `packages/swift/SocialWireRedis/Tests/` |
| ThinAppViewCore | `packages/swift/ThinAppViewCore/Tests/` |
| OperationsCore | `packages/swift/OperationsCore/Tests/` |
| iOS | `apps/apple/SocialWireTests/` |
| Lexicons | `packages/lexicons/__tests__/` |
| OpenAPI spec | `packages/spec/__tests__/` |

## Pull requests

- Use conventional commit messages (`fix:`, `feat:`, `docs:`, `test:`, etc.)
- Include tests for logic changes in the same PR
- Keep diffs focused — avoid drive-by refactors
- Update [docs/test-plans/](docs/test-plans/) when adding new test surfaces or commands

## Wiki edits

Edit wiki content only under **`docs/wiki/`** in this repository. On push to
`main`, [publish-wiki.yml](.github/workflows/publish-wiki.yml) validates the wiki
and syncs it to GitHub Wiki. The public
[Lichen wiki](https://lichen.wiki/@samclemente.me/the-social-wire) is currently
published separately from the same source; see
[docs/wiki/Contributing.md](docs/wiki/Contributing.md). Edits made only on either
hosted wiki can drift or be overwritten, so make the source change here first.

## Documentation

- Architecture narrative: [docs/architecture/](docs/architecture/)
- Package READMEs: each app/service/package root
- Agent memory (for Cursor): [AGENTS.md](AGENTS.md)

## Out of scope for automated CI

- Playwright / browser E2E
- macOS GitHub Actions or Xcode Cloud for iOS (local Cmd+U)
- Coverage percentage gates

## Branch protection

Require the **`CI — Required`** check from [.github/workflows/ci.yml](.github/workflows/ci.yml). It gates merges on path-filtered jobs for `web`, `operations-web`, `redis`, `gateway`, `appview`, `charybdis`, `operations`, `tap`, `lexicons`, and `spec`. Railway deployment remains independent and is handled by Railway's GitHub integration.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
