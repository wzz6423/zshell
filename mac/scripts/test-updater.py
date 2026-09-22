#!/usr/bin/env python3
"""Compile the real updater against vendored Sparkle and exercise feed/fallback behavior."""

from pathlib import Path
import os
import plistlib
import shutil
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
    module_cache = str(Path(directory) / "ModuleCache")
    contents = Path(directory) / "UpdaterTests.app/Contents"
    executable = contents / "MacOS/updater-tests"
    executable.parent.mkdir(parents=True)
    info = plistlib.loads((root / "mac/zshell/Info.plist").read_bytes())
    info.update({
        "CFBundleIdentifier": "sh.zshell.tests." + Path(directory).name,
        "CFBundleExecutable": executable.name,
        "CFBundleName": "UpdaterTests",
        "CFBundleDisplayName": "UpdaterTests",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "LSMinimumSystemVersion": "15.6",
        "LSUIElement": True,
        "SUEnableAutomaticChecks": False,
    })
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", module_cache,
        "-F", str(frameworks), "-typecheck", str(root / "mac/zshell/Updater.swift"),
    ], cwd=root, env=env, check=True)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-D", "DEBUG",
        "-module-cache-path", module_cache,
        "-F", str(frameworks), "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        str(root / "mac/zshell/Updater.swift"), str(root / "mac/tests/UpdaterTests.swift"),
        "-o", str(executable),
    ], cwd=root, env=env, check=True)
    shutil.copytree(frameworks / "Sparkle.framework", contents / "Frameworks/Sparkle.framework", symlinks=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(contents.parent)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
    try:
        subprocess.run([str(executable)], cwd=root, env=env, check=True, timeout=30)
    finally:
        bundle_id = info["CFBundleIdentifier"]
        subprocess.run(["/usr/bin/defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
        (Path.home() / "Library/Preferences" / f"{bundle_id}.plist").unlink(missing_ok=True)
