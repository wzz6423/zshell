"""Exercise the production FileTab and mounted AppKit source editor save path.

Build Debug first. ZSHELL_TEST_DERIVED_DATA selects an isolated build.
The probe's bundle, preferences, fixtures and binaries are removed afterwards.
"""
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running file save tests.")

with tempfile.TemporaryDirectory(prefix="zshell-file-save-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "File Save Probe.app"
    binary = bundle / "Contents/MacOS/probe"
    binary.parent.mkdir(parents=True)
    with (bundle / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": f"sh.zshell.test.file-save.{uuid.uuid4().hex}",
                      "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL"}, info)
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-target", f"{platform.machine()}-apple-macos15.6",
               "-module-cache-path", str(temporary / "ModuleCache"),
               "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                "-Xlinker", "-rpath", "-Xlinker", str(products),
                "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                str(ROOT / "mac/tests/FileTabSaveTests.swift"), "-o", str(binary)]
    subprocess.run(command, cwd=ROOT, check=True)
    home = temporary / "home"
    config = home / ".config/zshell-dev"
    config.mkdir(parents=True)
    (config / "config.toml").write_text("ai.enabled = false\n")
    fixture = temporary / "fixture"
    fixture.mkdir()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home))
    subprocess.run([str(binary), str(fixture)], cwd=ROOT, env=environment, check=True, timeout=30)
