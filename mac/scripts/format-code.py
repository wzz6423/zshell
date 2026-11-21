#!/usr/bin/env python3
"""Format tracked Swift and Rust sources without traversing build outputs."""

import argparse
from collections import defaultdict
from functools import cache
from pathlib import Path
import subprocess
import tomllib


ROOT = Path(__file__).resolve().parents[2]


@cache
def manifest_at(directory):
    path = directory / "Cargo.toml"
    return tomllib.loads(path.read_text()) if path.is_file() else {}


def rust_edition(path):
    for directory in (ROOT / path).parents:
        manifest = manifest_at(directory)
        if "package" in manifest:
            edition = manifest["package"].get("edition", "2015")
            if isinstance(edition, str):
                return edition
        edition = manifest.get("workspace", {}).get("package", {}).get("edition")
        if edition is not None:
            return edition
        if directory == ROOT:
            break
    raise ValueError(f"No Cargo edition found for {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    files = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "*.swift", "*.rs"], cwd=ROOT
    ).decode().split("\0")
    # Grammar inputs include invalid syntax and column-sensitive highlight markers.
    swift = [path for path in files if path.endswith(".swift") and "/tree-sitter-swift/test/" not in path]
    fixture_count = sum(path.endswith(".swift") for path in files) - len(swift)
    rust = defaultdict(list)
    for path in files:
        if path.endswith(".rs"):
            rust[rust_edition(path)].append(path)

    subprocess.run(
        ["xcrun", "swift-format", "lint" if options.check else "format",
         "--strict" if options.check else "--in-place", "--parallel",
         "--configuration", str(ROOT / ".swift-format"), *swift],
        cwd=ROOT, check=True,
    )
    for edition, paths in sorted(rust.items()):
        arguments = ["rustfmt", "--edition", edition, "--config-path", str(ROOT / "rustfmt.toml"),
                     "--config", "skip_children=true"]
        if options.check:
            arguments.append("--check")
        subprocess.run(
            [*arguments, *paths], cwd=ROOT, check=True,
        )
    print(f"{'Checked' if options.check else 'Formatted'} {len(swift)} Swift and "
          f"{sum(map(len, rust.values()))} Rust files; preserved {fixture_count} grammar fixtures.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
