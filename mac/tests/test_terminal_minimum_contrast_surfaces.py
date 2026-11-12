"""Exercise minimum contrast on native terminal surfaces and their real pixels.

Build Debug first. The probe uses private settings, PTYs, and app resources.
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
    default=Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")))
parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
options = parser.parse_args()
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app/Contents"
library = app / "MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build Debug in {options.derived_data} before running contrast tests")

with tempfile.TemporaryDirectory(prefix="zshell-contrast-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "ContrastTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.contrast-tests." + uuid.uuid4().hex,
        "CFBundleExecutable": "zshell", "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "TerminalMinimumContrastSurfaceProbe",
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
        str(ROOT / "mac/tests/TerminalMinimumContrastSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift")]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in options.backend or ("alacritty", "ghostty"):
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "sh.zshell.contrast-tests." + uuid.uuid4().hex,
            "CFBundleExecutable": "zshell", "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        home = temporary / backend
        home.mkdir()
        config = home / ".config/zshell/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('theme = "dark"\nai.enabled = false\n'
                          'terminal.preserve-sessions = false\nterminal.minimum-contrast = 3\n')
        development = home / ".config/zshell-dev"
        development.mkdir(parents=True)
        (development / "config.toml").write_text(config.read_text())
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux")})
        subprocess.run([str(binary), backend,
            str(ROOT / "mac/tests/fixtures/terminal_minimum_contrast.py")],
            cwd=ROOT, env=environment, check=True, timeout=120)
