"""Exercise production right-click input on both backends with isolated raw PTYs.

Build Debug first, then pass --derived-data. The probe uses disposable homes,
restores the clipboard and never takes desktop focus or touches a live shell.
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
parser.add_argument("--derived-data", type=Path,
                    default=os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
parser.add_argument("--cell-width", type=float, choices=(0.75, 1.0, 1.35, 2.0), action="append")
options = parser.parse_args()
if not options.derived_data:
    parser.error("--derived-data must point to a completed Debug app build")
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build Debug in {options.derived_data} first")

with tempfile.TemporaryDirectory(prefix="zshell-right-click-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    contents = temporary / "RightClickProbe.app/Contents"
    binary = contents / "MacOS/RightClickProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Contents/Resources")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info.update(CFBundleIdentifier="sh.zshell.right-click-test." + uuid.uuid4().hex,
                CFBundleExecutable=binary.name, LSUIElement=True, SUEnableAutomaticChecks=False)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
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
        str(ROOT / "mac/tests/TerminalRightClickSurfaceTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        for cell_width in options.cell_width or (1.0,):
            home = temporary / f"{backend}-{cell_width}"
            (home / "tmp").mkdir(parents=True)
            config = home / ".config/zshell-dev/config.toml"
            config.parent.mkdir(parents=True)
            config.write_text('ai.enabled = false\nquick-terminal.enabled = false\n'
                              'terminal.preserve-sessions = false\nterminal.restore-history = false\n')
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
            })
            subprocess.run([str(binary), backend, str(ROOT / "mac/tests/fixtures/terminal_right_click.py"),
                            str(home / "input"), str(cell_width)],
                           cwd=ROOT, env=environment, check=True, timeout=90)
