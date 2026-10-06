#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SOURCES="$REPO_ROOT/packages/swift/WireCore/Sources/WireCore"
swiftc -module-cache-path "$WORK_DIR/module-cache" -parse-as-library -o "$WORK_DIR/swift-ranker" \
 "$SOURCES/WireRanker.swift" "$SOURCES/WireCandidate.swift" \
 "$SOURCES/WireRankingConfig.swift" "$SOURCES/WireRankingConfigError.swift" \
 "$SOURCES/WireRankingWeights.swift" "$SOURCES/WireDomainPenaltyPolicy.swift" \
 "$SOURCES/WireDiversityPolicy.swift" "$SOURCES/WireDiversityReranker.swift" \
 "$SOURCES/WireDiversityIntervention.swift" "$SOURCES/WireDiversityResult.swift" \
 "$SOURCES/WireRankingResult.swift" "$SOURCES/WireRankingDiagnostics.swift" \
 "$SOURCES/WireScoredCandidate.swift" "$SOURCES/WireReasonCode.swift" \
 "$SOURCES/WireTargetKind.swift" "$SOURCES/WireCommercialAssessment.swift" \
 "$REPO_ROOT/scripts/go/ranking-oracle.swift"
GOWORK=off go -C "$REPO_ROOT/packages/go" build -o "$WORK_DIR/go-ranker" ./cmd/ranking-parity
python3 "$REPO_ROOT/scripts/go/verify-ranking-parity.py" --swift "$WORK_DIR/swift-ranker" --go "$WORK_DIR/go-ranker"
