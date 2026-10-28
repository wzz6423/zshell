"""Exercise native local PNG/TIFF paste and cancellation on both real backends.

Build Debug first. Use --derived-data for an isolated build; this probe uses
disposable terminal homes, private temporary directories and no live app window.
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path,
    default=Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")))
parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
options = parser.parse_args()
build = options.derived_data / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} before running local clipboard surface tests")

with tempfile.TemporaryDirectory(prefix="zshell-local-clipboard-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / ("zshellClipboardProbe_" + uuid.uuid4().hex)
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
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(binary),
        str(ROOT / "mac/tests/LocalClipboardImageSurfaceTests.swift")]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        home = temporary / backend / "home"
        home.mkdir(parents=True)
        files = temporary / backend / "temporary"
        files.mkdir(mode=0o700)
        environment = {key: value for key, value in os.environ.items()
            if key not in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN")}
        environment.update({"CFFIXED_USER_HOME": str(home), "HOME": str(home),
            "TMPDIR": str(files), "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        subprocess.run([str(binary), backend], cwd=ROOT, check=True, timeout=90, env=environment)
