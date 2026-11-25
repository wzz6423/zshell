"""Compile and exercise the production local secret detector without app state."""

from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="zshell-redaction-model-tests-", dir="/tmp") as directory:
    binary = Path(directory) / "redaction-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-O",
        "-module-cache-path", str(Path(directory) / "ModuleCache"),
        str(root / "mac/zshell/TerminalSecretRedaction.swift"),
        str(root / "mac/tests/TerminalSecretRedactionTests.swift"), "-o", str(binary),
    ], cwd=root, check=True, timeout=120)
    subprocess.run([str(binary)], cwd=root, check=True, timeout=60)
