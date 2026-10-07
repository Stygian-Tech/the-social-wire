#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SOURCES="$REPO_ROOT/packages/swift/WireCore/Sources/WireCore"
FILES=()
for NAME in WireEditionAssembler WireEdition WireFeedItem WireItemSource WireReasonCode WireProvenanceKind WireEditionPublication WireEditionPublicationPanel WireEditionStoryRail WireTalkedAboutAccount WireTalkedAboutAccountCandidate WirePageSource; do
  FILES+=("$SOURCES/$NAME.swift")
done
swiftc -module-cache-path "$WORK_DIR/module-cache" -parse-as-library -o "$WORK_DIR/swift-edition" "${FILES[@]}" "$REPO_ROOT/scripts/go/edition-oracle.swift"
GOWORK=off go -C "$REPO_ROOT/packages/go" build -o "$WORK_DIR/go-edition" ./cmd/edition-parity
python3 "$REPO_ROOT/scripts/go/verify-edition-parity.py" --swift "$WORK_DIR/swift-edition" --go "$WORK_DIR/go-edition"
