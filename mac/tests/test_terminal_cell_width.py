"""Exercise both production terminal backends from an isolated signed Debug build.

python3 mac/tests/test_terminal_cell_width.py --derived-data /tmp/derived-data
All windows remain hidden and offscreen; fixture homes and binaries are removed.
"""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", required=True, type=Path)
options = parser.parse_args()
build = options.derived_data / "Build"
products = build / "Products/Debug"
application = products / "zshell Debug.app"
library = application / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} first")

with tempfile.TemporaryDirectory(prefix="zshell-cell-width-probe-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "CellWidthProbe.app/Contents"
    binary = contents / "MacOS/CellWidthProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(application / "Contents/Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.cell-width-tests." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(products), "-I", str(products / "include"), "-F", str(products),
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
        str(ROOT / "mac/tests/TerminalCellWidthSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in ("ghostty", "alacritty"):
        home = temporary / backend
        home.mkdir()
        config = home / ".config/zshell-dev/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("ai.enabled = false\nterminal.preserve-sessions = false\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                            "ZDOTDIR": str(home), "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        subprocess.run([str(binary), backend, str(ROOT / "mac/tests/fixtures/terminal_cell_width.py"),
                        str(home)], cwd=ROOT, env=environment, check=True, timeout=75)
