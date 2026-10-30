"""Compile @testable probes against an isolated Debug app, then use real PTYs.

ZSHELL_TEST_DERIVED_DATA=/tmp/derived python3 mac/tests/test_terminal_hint_surfaces.py
Run only while holding the cross-chat app-build/surface lock.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} first")

with tempfile.TemporaryDirectory(prefix="zshell-hint-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "hint-surfaces"
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6",
                 "-module-cache-path", str(temporary / "ModuleCache"),
                 "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                  "-Xlinker", "-rpath", "-Xlinker", str(products),
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(binary)]
    subprocess.run(arguments + [str(ROOT / "mac/tests/TerminalHintSurfaceTests.swift")], cwd=ROOT, check=True)
    for backend in ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN")}
        environment["CFFIXED_USER_HOME"] = str(home)
        subprocess.run([str(binary), backend, str(ROOT / "mac/tests/fixtures/terminal_hints.py"), str(home / "input")],
                       cwd=ROOT, env=environment, check=True, timeout=90)
