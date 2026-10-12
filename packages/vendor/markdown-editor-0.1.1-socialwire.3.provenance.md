# Markdown Editor Social Wire Patch

- Package: `@stygian/markdown-editor@0.1.1-socialwire.3`
- Upstream: `https://github.com/Stygian-Tech/anypub`, `packages/block-editor`
- Source revision: `7abb08a2cbe7f06379dfe409e9619b90b5e6df5e`
- Reviewed source patch: `markdown-editor-0.1.1-socialwire.3.patch`
- Patch SHA-256: `a64c476251a16008a63d021a2a172713deb6606d782567614f36c1d1016621fd`
- Artifact SHA-256: `2d91ec42af16cdfa6cb6f27c4eaecfd08f311f1be354ff917abbc494d51c06cc`
- Build tool: Bun 1.3.7. Built from an isolated archive; the AnyPub checkout was not modified. No registry publication.
- License: upstream contains no LICENSE file or SPDX declaration. Reused for the owner's authorized Social Wire integration, as with the original vendored artifact.

## Rebuild

Set `ANYPUB_CHECKOUT` to an AnyPub clone containing the pinned revision and `VENDOR_DIR` to this directory. The patch applies at the block-editor package root.

```sh
stage=$(mktemp -d)
git -C "$ANYPUB_CHECKOUT" archive 7abb08a2cbe7f06379dfe409e9619b90b5e6df5e packages/block-editor | tar -xf - -C "$stage"
cd "$stage/packages/block-editor"
patch -p1 < "$VENDOR_DIR/markdown-editor-0.1.1-socialwire.3.patch"
bun install
bun run build
bun run test
bun pm pack --filename "$VENDOR_DIR/markdown-editor-0.1.1-socialwire.3.tgz" --quiet
```

The isolated upstream lint configuration expects a Next.js peer; validation supplied the existing Social Wire Next.js installation without changing package dependencies. Archive timestamps may differ on a rebuild; the patch and pinned revision are the reviewable source of truth.

## Changes and Compatibility

Recognizes adjacent headings, thematic breaks, quotes, lists, images, and fenced blocks without requiring blank lines. Supports setext headings, variable-length backtick/tilde fences, and unclosed fences. Untouched editor blur preserves exact source; controlled value changes replace the selected document. Read-only rendering groups semantic nested lists, preserves heading levels, and allows link navigation; editor preview links continue suppressing navigation.

This remains the existing portable Markdown subset, not a full CommonMark parser. Tables, reference definitions, raw HTML blocks, and complete lazy/multiblock list or quote semantics remain unsupported. List indentation follows the existing two-space-or-tab model. HTML stays escaped and unsafe links are not rendered as anchors. Native article publishing uses exported heading/code helpers so delimiters do not enter published text.

Validation: upstream 22 parser tests; focused Web package and article publishing tests; package build and lint, plus Web typecheck and targeted lint. The parent change separately validates workspace modes, styles, browser behavior, full coverage, and production build.
