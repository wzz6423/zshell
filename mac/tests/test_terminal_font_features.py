"""Exercise font features in the compiled Debug app, real PTYs, and Metal.

Build mac/build/debug first, or set ZSHELL_TEST_DERIVED_DATA to an isolated build:
    python3 mac/tests/test_terminal_font_features.py
The fixture opens no visible windows and cleans its temporary app and settings.
"""

import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} before running font feature tests.")

with tempfile.TemporaryDirectory(prefix="zshell-font-features-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    contents = temporary / "FontFeatureTests.app/Contents"
    resources = contents / "Resources"
    resources.mkdir(parents=True)
    binary = contents / "MacOS/FontFeatureTests"
    binary.parent.mkdir()
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"sh.zshell.dev.font-feature-tests.{uuid.uuid4().hex}",
        "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        # Debug never starts Sparkle; fixture values satisfy its initialization.
        "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "SUFeedURL": "https://example.com/appcast.xml",
        "ZshellReleaseFallbackAppcastURL": "https://example.com/fallback/appcast.xml",
    }))
    for source in (APP / "Contents/Resources").glob("*.lproj"):
        shutil.copytree(source, resources / source.name)
    for source in (ROOT / "mac/zshell/Fonts").glob("*.ttf"):
        shutil.copy2(source, resources / source.name)

    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(LIBRARY),
        "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        "-o", str(binary), str(ROOT / "mac/tests/TerminalFontFeaturesTests.swift"),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {
            key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")
        }
        environment.update({
            "CFFIXED_USER_HOME": str(home),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
        })
        subprocess.run(
            [str(binary), backend, str(home)],
            cwd=ROOT, env=environment, check=True, timeout=90,
        )
