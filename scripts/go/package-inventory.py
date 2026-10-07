#!/usr/bin/env python3
"""Record the source baseline for every repository-owned shared package.

This is a contract inventory, not a claim of implementation or runtime parity.
"""

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAPPINGS = {
    "WireCore": "wirecore",
    "ThinAppViewCore": "thinappviewcore",
    "OperationsCore": "operationscore",
    "ReadStateCore": "readstatecore",
    "SocialWireRedis": "socialwireredis",
    "FinanceCore": "financecore",
    "SportsCore": "sportscore",
    "GatewayCore": "gatewaycore",
}


def inventory():
    packages = []
    for manifest in sorted((ROOT / "packages/swift").glob("*/Package.swift")):
        directory = manifest.parent
        sources = []
        for path in sorted(directory.glob("Sources/**/*.swift")):
            text = path.read_text()
            sources.append(
                {
                    "path": str(path.relative_to(ROOT)),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "lines": len(text.splitlines()),
                    "publicDeclarations": [
                        line.strip()
                        for line in text.splitlines()
                        if re.match(
                            "\\s*public (?:static |class |final |mutating |nonisolated )*(?:struct|enum|actor|class|protocol|func|var|let|init)",
                            line,
                        )
                    ],
                }
            )
        name = directory.name
        packages.append(
            {
                "name": name,
                "source": str(directory.relative_to(ROOT)),
                "target": "packages/go/" + MAPPINGS.get(name, name.lower()),
                "sources": sources,
                "tests": [
                    str(source_path.relative_to(ROOT))
                    for source_path in sorted(directory.glob("Tests/**/*.swift"))
                ],
            }
        )
    for manifest in sorted((ROOT / "packages").glob("*/package.json")):
        directory = manifest.parent
        if directory.name == "swift":
            continue
        packages.append(
            {
                "name": directory.name,
                "source": str(directory.relative_to(ROOT)),
                "target": "packages/go/" + directory.name.replace("-", ""),
                "files": [
                    {
                        "path": str(source_path.relative_to(ROOT)),
                        "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                    }
                    for source_path in sorted(directory.rglob("*"))
                    if source_path.is_file()
                    and source_path.suffix in {".ts", ".json", ".yaml"}
                    and ("node_modules" not in source_path.parts)
                ],
            }
        )
    libraries = []
    for directory in sorted((ROOT / "services").glob("*/Sources/*Core")):
        source_paths = sorted(directory.rglob("*.swift"))
        if not source_paths:
            continue
        libraries.append(
            {
                "name": directory.name,
                "source": str(directory.relative_to(ROOT)),
                "target": "packages/go/" + directory.name.lower(),
                "files": [
                    {
                        "path": str(source_path.relative_to(ROOT)),
                        "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                        "lines": len(source_path.read_text().splitlines()),
                    }
                    for source_path in source_paths
                ],
            }
        )
    retired_path = ROOT / "packages/go/migration/retired-worker-sources.json"
    retired = json.loads(retired_path.read_text()) if retired_path.exists() else None
    services_path = ROOT / "packages/go/migration/retired-service-sources.json"
    retired_services = json.loads(services_path.read_text()) if services_path.exists() else None
    return {
        **({"retiredWorkers": retired} if retired is not None else {}),
        **({"retiredServices": retired_services} if retired_services is not None else {}),
        "schemaVersion": 1,
        "description": "Source inventory; implementation and parity must be tracked separately.",
        "packages": packages,
        "serviceLibraries": libraries,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    destination = ROOT / "packages/go/migration/source-inventory.json"
    expected = json.dumps(inventory(), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if not destination.exists() or destination.read_text() != expected:
            raise SystemExit(
                "Go migration source inventory is stale; regenerate and review changed contracts."
            )
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(expected)
