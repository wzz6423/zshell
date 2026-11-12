"""Exercise file-tree copies and rollback against disposable real directories."""

import argparse
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref", help="Replay the same assertions against an earlier import service")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zshell-file-import-tests-", dir="/tmp") as directory:
        temporary = Path(directory)
        binary = temporary / "file-import-tests"
        service = temporary / "FileTreeImportService.swift"
        service_source = ((ROOT / "mac/zshell/FileTreeImportService.swift").read_text() if not options.source_ref
                          else subprocess.check_output([
                "git", "show", f"{options.source_ref}:mac/zshell/FileTreeImportService.swift",
            ], cwd=ROOT, text=True))
        boundary = "            return entries.map { plan.directory.appendingPathComponent($0.name).path }"
        if service_source.count(boundary) != 1:
            raise SystemExit("Expected exactly one production publish-completion boundary")
        # Pause only a temporary source copy after publication; copying and rollback stay unchanged.
        service.write_text(service_source.replace(boundary,
            "            ImportRollbackRaceFixture.afterPublish(plan)\n            try operation.checkCancellation()\n" + boundary))
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor", "-warnings-as-errors", "-O",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "modules"),
            str(ROOT / "mac/zshell/AppLocalization.swift"),
            str(ROOT / "mac/zshell/SettingsConfigFile.swift"),
            str(service),
            str(ROOT / "mac/tests/FileTreeImportTests.swift"), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=90)


if __name__ == "__main__":
    main()
