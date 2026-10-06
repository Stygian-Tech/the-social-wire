#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Compile actual rankers and models as one test executable. Only imports of
# WireCore are removed to avoid building unrelated network-dependent packages.
# Resolver version constants and Sports normalize come from the actual sources;
# this oracle verifies ranking, not article resolution or reviewed catalogs.
python3 - "$REPO_ROOT" "$WORK_DIR" <<'PY'
import hashlib, pathlib, re, sys
root,work=map(pathlib.Path,sys.argv[1:])
packages=root/'packages/swift'
files={'WireCore':['WireFeedItem','WireItemSource','WireReasonCode','WireProvenanceKind'],
       'FinanceCore':['FinanceRanker','FinanceRankCandidate','FinanceArticleAnalysis','FinanceAssociation'],
       'SportsCore':['SportsRanker','SportsRankCandidate','SportsArticleAnalysis','SportsAssociation','SportsEntity','SportsMembership','SportsSelection','SportsSportHierarchy']}
for package,names in files.items():
    for name in names:
        source=(packages/package/'Sources'/package/(name+'.swift')).read_text()
        (work/(name+'.swift')).write_text(source.replace('import WireCore\n',''))
finance=(packages/'FinanceCore/Sources/FinanceCore/FinanceResolver.swift').read_text()
version=re.search(r'public static let version = "([^"]+)"',finance).group(1)
sports=(packages/'SportsCore/Sources/SportsCore/SportsResolver.swift').read_text()
helpers=sports[:sports.index('  public static func analyze(')]+'}\n'
identities={seed:'sp_'+hashlib.sha256(seed.encode()).hexdigest()[:32] for seed in ['sport:ice-hockey','sport:winter-sports']}
support='public enum FinanceResolver { public static let version = "'+version+'" }\n'+helpers
support+='enum SportsReviewedCatalog { static func id(_ seed: String) -> String {\n'
for seed,identity in identities.items():support+='if seed == "'+seed+'" { return "'+identity+'" }\n'
support+='fatalError("Unexpected hierarchy identity")\n} }\n'
(work/'Support.swift').write_text(support)
PY
swiftc -module-cache-path "$WORK_DIR/module-cache" -parse-as-library -o "$WORK_DIR/swift-domain-ranker" "$WORK_DIR"/*.swift "$REPO_ROOT/scripts/go/domain-ranking-oracle.swift"
GOWORK=off go -C "$REPO_ROOT/packages/go" build -o "$WORK_DIR/go-domain-ranker" ./cmd/domain-ranking-parity
python3 "$REPO_ROOT/scripts/go/verify-domain-ranking-parity.py" --swift "$WORK_DIR/swift-domain-ranker" --go "$WORK_DIR/go-domain-ranker"
