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
| API | `services/api/Tests/AppTests/` |
| Worker | `services/worker/Tests/` |
| ThinAppViewCore | `packages/swift/ThinAppViewCore/Tests/` |
| iOS | `apps/apple/SocialWireTests/` |
| Lexicons | `packages/lexicons/__tests__/` |
| OpenAPI spec | `packages/spec/__tests__/` |

## Pull requests

- Use conventional commit messages (`fix:`, `feat:`, `docs:`, `test:`, etc.)
- Include tests for logic changes in the same PR
- Keep diffs focused — avoid drive-by refactors
- Update [docs/test-plans/](docs/test-plans/) when adding new test surfaces or commands

## Wiki edits

Edit wiki content only under **`docs/wiki/`** in this repository. On push to `main`, [publish-wiki.yml](.github/workflows/publish-wiki.yml) syncs to GitHub Wiki (edits made only on GitHub Wiki are overwritten).

## Documentation

- Architecture narrative: [docs/architecture/](docs/architecture/)
- Package READMEs: each app/service/package root
- Agent memory (for Cursor): [AGENTS.md](AGENTS.md)

## Out of scope for automated CI

- Playwright / browser E2E
- macOS GitHub Actions or Xcode Cloud for iOS (local Cmd+U)
- Coverage percentage gates

## Branch protection

Require the **`CI — required`** check from [.github/workflows/ci.yml](.github/workflows/ci.yml). It gates merges on path-filtered jobs (`build-web`, `test-api`, `test-lexicons`, `test-spec`, `test-worker`, `supabase-validate`).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
