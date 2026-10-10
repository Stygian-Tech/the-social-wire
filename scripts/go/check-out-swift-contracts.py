#!/usr/bin/env python3
"""Materialize immutable Swift reference contracts without modifying existing work."""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], text=True, stderr=subprocess.PIPE
    ).strip()


def verify(directory, package):
    if not (directory / ".git").is_dir():
        raise ValueError(f"{directory} is not an independent Git checkout")
    if Path(git(directory, "rev-parse", "--show-toplevel")).resolve() != directory.resolve():
        raise ValueError(f"{directory} is not its own repository root")
    if git(directory, "remote", "get-url", "origin") != package["repository"]:
        raise ValueError(f"{directory} has an unexpected origin")
    if git(directory, "rev-parse", "HEAD") != package["revision"]:
        raise ValueError(f"{directory} does not match the pinned revision")
    if git(directory, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"{directory} has local changes")


def checkout(root, manifest, selected):
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported Swift contract manifest schema")
    packages = manifest["packages"]
    names = [package["name"] for package in packages]
    if len(names) != len(set(names)):
        raise ValueError("Duplicate Swift contract package names")
    if set(selected) - set(names):
        raise ValueError("Unknown selected Swift contract package")
    # Validate every pin before any checkout is created.
    for package in packages:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", package["name"]):
            raise ValueError("Invalid Swift contract package name")
        if not re.fullmatch(r"[0-9a-f]{40}", package["revision"]):
            raise ValueError(f"{package['name']} requires a full immutable Git revision")
        if not package["repository"] or package["repository"].startswith("-"):
            raise ValueError("Invalid Swift contract repository")
    for package in packages:
        if selected and package["name"] not in selected:
            continue
        directory = root / "packages/swift" / package["name"]
        if directory.exists() or directory.is_symlink():
            if directory.is_symlink():
                raise ValueError(f"{directory} must not be a symlink")
            verify(directory, package)
        else:
            directory.parent.mkdir(parents=True, exist_ok=True)
            temporary = Path(tempfile.mkdtemp(prefix=f".{package['name']}-", dir=directory.parent))
            try:
                git(temporary, "init", "--quiet")
                git(temporary, "remote", "add", "origin", package["repository"])
                git(temporary, "fetch", "--quiet", "--depth=1", "origin", package["revision"])
                git(temporary, "checkout", "--quiet", "--detach", package["revision"])
                verify(temporary, package)
                temporary.rename(directory)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        print(f"Verified {package['name']} at {package['revision']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--package", action="append", default=[])
    args = parser.parse_args()
    manifest_path = args.manifest or args.root / "packages/go/migration/extracted-swift-packages.json"
    try:
        checkout(args.root.resolve(), json.loads(manifest_path.read_text()), args.package)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Swift contract checkout failed: {error}") from error
