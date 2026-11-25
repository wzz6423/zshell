"""Compile the production session-local bookmark store and native record decoder."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-command-bookmarks-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "bookmark-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(temporary / "ModuleCache"),
        str(ROOT / "mac/zshell/TerminalCommandRecord.swift"),
        str(ROOT / "mac/zshell/TerminalCommandRecords.swift"),
        str(ROOT / "mac/zshell/TerminalCommandBookmarks.swift"),
        str(ROOT / "mac/tests/TerminalCommandBookmarkTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=30)
