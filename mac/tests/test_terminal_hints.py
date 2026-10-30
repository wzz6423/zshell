"""Verify the shipped hint matcher without an app build or a live user window."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-hint-matcher-") as directory:
    binary = Path(directory) / "hints"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(Path(directory) / "ModuleCache"),
        str(ROOT / "mac/zshell/TerminalViewportSnapshot.swift"),
        str(ROOT / "mac/zshell/TerminalHintMatcher.swift"),
        str(ROOT / "mac/tests/TerminalHintMatcherTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=45)
