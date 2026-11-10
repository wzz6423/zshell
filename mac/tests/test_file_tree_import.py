"""Exercise file-tree copies and rollback against disposable real directories."""

from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="zshell-file-import-tests-", dir="/tmp") as directory:
        temporary = Path(directory)
        binary = temporary / "file-import-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor", "-warnings-as-errors", "-O",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "modules"),
            str(ROOT / "mac/zshell/AppLocalization.swift"),
            str(ROOT / "mac/zshell/SettingsConfigFile.swift"),
            str(ROOT / "mac/zshell/FileTreeImportService.swift"),
            str(ROOT / "mac/tests/FileTreeImportTests.swift"), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=90)


if __name__ == "__main__":
    main()
