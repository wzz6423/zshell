"""Exercise production AppKit pointer focus without taking desktop input.

Run the container regression with no app build:
    python3 mac/tests/test_pointer_focus.py

After building Debug, also exercise both real backends, the native settings
switch and Quick Terminal:
    python3 mac/tests/test_pointer_focus.py --derived-data /tmp/derived-data
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path)
options = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="zshell-pointer-focus-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "pointer-focus-tests"
    cache = temporary / "ModuleCache"
    source = (ROOT / "mac/zshell/TerminalHostView.swift").read_text()
    container = temporary / "TerminalContainerView.swift"
    container.write_text("import AppKit\n" + source[source.index("final class TerminalContainerView: NSView"):])
    probe = ROOT / "mac/tests/PointerFocusTests.swift"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(cache), str(container), str(probe), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=15)

    if options.derived_data:
        build = options.derived_data / "Build"
        products = build / "Products/Debug"
        library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
        if not library.is_file():
            raise SystemExit(f"Build the Debug app in {options.derived_data} first")
        arguments = [
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-D", "ZSHELL_POINTER_FOCUS_APP",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(cache), "-I", str(products),
            "-I", str(products / "include"), "-F", str(products),
        ]
        for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
            arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
        for include in (
            "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
            "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
        ):
            path = ROOT / "mac/Vendor" / include
            arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
        arguments += [
            "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
            "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
            "-Xlinker", "-rpath", "-Xlinker", str(products),
            "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
            str(probe), "-o", str(binary),
        ]
        subprocess.run(arguments, cwd=ROOT, check=True)
        for backend in ("ghostty", "alacritty"):
            home = temporary / backend
            home.mkdir()
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
            })
            subprocess.run([str(binary), backend], cwd=ROOT, env=environment, check=True, timeout=30)
