"""Exercise production Git timeout/cancellation and both synchronous entry points.

Run: python3 mac/tests/test_git_command_runner.py
Fixtures, binaries, and module caches live in a temporary directory. Sleeping
helpers expire after three seconds even if a regression aborts the probe.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "mac/zshell/GitStatusModel.swift").read_text()
start = source.index("    nonisolated static func runGit(")
end = source.index("    /// Runs Git over SSH", start)

with tempfile.TemporaryDirectory(prefix="zshell-git-process-timeout-", dir="/tmp") as directory:
    temporary = Path(directory)
    model = temporary / "GitStatusModel.swift"
    model.write_text("import Foundation\nnonisolated enum GitStatusModel {\n" + source[start:end] + "}\n")
    binary = temporary / "probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        str(ROOT / "mac/zshell/GitProxy.swift"), str(ROOT / "mac/zshell/GitCommandRunner.swift"),
        str(model), str(ROOT / "mac/tests/GitCommandRunnerTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True, timeout=90)
    fixture = temporary / "目录 with space"
    fixture.mkdir()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    completed = False
    try:
        subprocess.run([str(binary), str(fixture)], cwd=ROOT, env=environment, check=True, timeout=45)
        completed = True
    finally:
        # Every helper is finite. On a crashed or timed-out probe, let the
        # remaining three-second fixtures expire before deleting their files.
        if not completed:
            time.sleep(3)
