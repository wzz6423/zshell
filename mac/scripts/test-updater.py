#!/usr/bin/env python3
"""Compile the real updater against vendored Sparkle and exercise feed/fallback behavior."""

from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
frameworks = root / "mac/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
env = dict(os.environ)
if "DEVELOPER_DIR" not in env:
    beta = Path("/Applications/Xcode-beta.app/Contents/Developer")
    if beta.is_dir():
        env["DEVELOPER_DIR"] = str(beta)

with tempfile.TemporaryDirectory(prefix="zshell-updater-tests-") as directory:
    executable = Path(directory) / "updater-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-D", "DEBUG",
        "-F", str(frameworks), "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
        str(root / "mac/zshell/Updater.swift"), str(root / "mac/tests/UpdaterTests.swift"),
        "-o", str(executable),
    ], cwd=root, env=env, check=True)
    subprocess.run([str(executable)], cwd=root, env=env, check=True)
