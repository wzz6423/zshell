"""Exercise profile switching in real AppKit terminal panes and PTYs."""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
PRODUCTS = BUILD / "Products/Debug"
LIBRARY = PRODUCTS / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} first")

with tempfile.TemporaryDirectory(prefix="zshell-profile-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    binary = temporary / "profile-surface-tests"
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
        "-o", str(binary), str(ROOT / "mac/tests/TerminalProfileSurfaceTests.swift"),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        subprocess.run([str(binary), backend, str(home)], cwd=ROOT, env=environment, check=True, timeout=90)
