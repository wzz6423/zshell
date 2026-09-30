"""Run real terminal views and PTYs against the Debug app's compiled code.

Build mac/build/debug first, then run:
    python3 mac/tests/test_terminal_ai_input_surfaces.py
No live app window, Claude account, or user draft is used.
"""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
build = root / "mac/build/debug/Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit("Build the Debug app in mac/build/debug before running surface tests.")

with tempfile.TemporaryDirectory(prefix="zshell-input-surfaces-") as directory:
    binary = Path(directory) / "terminal-input-tests"
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(Path(directory) / "ModuleCache"),
        "-I", str(products), "-I", str(products / "include"), "-F", str(products),
    ]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = root / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"),
        str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(binary),
    ]
    for suite in ("TerminalPromptSelectionSurfaceTests", "TerminalAIInputSurfaceTests"):
        source = root / "mac/tests" / (suite + ".swift")
        subprocess.run(arguments + [str(source)], cwd=root, check=True)
        for backend in ("alacritty", "ghostty"):
            subprocess.run([
                str(binary), backend, str(root / "mac/tests/fixtures/claude.py"),
            ], cwd=root, check=True, timeout=30,
                env={**os.environ, "CFFIXED_USER_HOME": directory})
