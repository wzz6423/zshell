#!/usr/bin/env python3
"""Exercise real Sparkle preferences in an isolated app, including process restarts."""

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

with tempfile.TemporaryDirectory(prefix="updater-preferences-") as directory:
    contents = Path(directory) / "UpdaterPreferencesTests.app/Contents"
    executable = contents / "MacOS/updater-preference-tests"
    executable.parent.mkdir(parents=True)
    info = plistlib.loads((root / "mac/zshell/Info.plist").read_bytes())
    info.update({
        "CFBundleIdentifier": "sh.zshell.tests." + Path(directory).name,
        "CFBundleExecutable": executable.name,
        "CFBundleName": "UpdaterPreferencesTests",
        "CFBundleDisplayName": "UpdaterPreferencesTests",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "LSMinimumSystemVersion": "15.6",
        "LSUIElement": True,
    })
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-D", "DEBUG",
        "-module-cache-path", str(Path(directory) / "module-cache"),
        "-F", str(frameworks), "-framework", "Sparkle",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        str(root / "mac/zshell/Updater.swift"), str(root / "mac/tests/UpdaterPreferencesTests.swift"),
        "-o", str(executable),
    ], cwd=root, env=env, check=True)
    shutil.copytree(frameworks / "Sparkle.framework", contents / "Frameworks/Sparkle.framework", symlinks=True)

    def sign():
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(contents.parent)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)

    bundle_ids = [info["CFBundleIdentifier"]]
    try:
        sign()
        for phase in ("fresh", "restore-disabled", "restore-enabled", "restore-opted-out"):
            subprocess.run([str(executable), phase], cwd=root, env=env, check=True, timeout=30)

        info["CFBundleIdentifier"] += ".disallowed"
        info["SUAllowsAutomaticUpdates"] = False
        bundle_ids.append(info["CFBundleIdentifier"])
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        sign()
        subprocess.run([str(executable), "disallowed"], cwd=root, env=env, check=True, timeout=30)
    finally:
        for bundle_id in bundle_ids:
            subprocess.run(["/usr/bin/defaults", "delete", bundle_id],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
            (Path.home() / "Library/Preferences" / f"{bundle_id}.plist").unlink(missing_ok=True)
