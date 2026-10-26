"""Run production worktree creation and cleanup against disposable Git repositories."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix="zshell-session-worktree-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "worktree-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        str(ROOT / "mac/zshell/GitCommandRunner.swift"),
        str(ROOT / "mac/zshell/SessionWorktreeService.swift"),
        str(ROOT / "mac/tests/SessionWorktreeTests.swift"), "-o", str(binary),
    ], check=True)
    environment = os.environ.copy()
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
    subprocess.run([str(binary), str(temporary)], env=environment, check=True)
