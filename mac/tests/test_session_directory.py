"""Verify local session directory resolution against disposable filesystem fixtures."""

from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-session-directory-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "directory-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-module-cache-path", str(temporary / "modules"),
        str(ROOT / "mac/zshell/TerminalSessionDirectory.swift"),
        str(ROOT / "mac/tests/TerminalSessionDirectoryTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(temporary)], check=True, timeout=10)
