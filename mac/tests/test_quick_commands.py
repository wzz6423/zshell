"""Verify parameterized quick commands against the compiled Debug module and real shells.

Build Debug first, then pass --derived-data. Native controls use offscreen
windows unless --gui is requested. Each probe has a private HOME and defaults
domain; its binaries, PTYs and module cache are removed after the run.
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
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
parser.add_argument("--model-only", action="store_true")
parser.add_argument("--compile-only", action="store_true")
parser.add_argument("--gui", action="store_true")
options = parser.parse_args()
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit("Build the Debug app before running quick command checks.")

with tempfile.TemporaryDirectory(prefix="zshell-quick-command-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
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
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
        str(library), "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
    ]
    contents = temporary / "QuickCommandTests.app/Contents"
    binary_directory = contents / "MacOS"
    binary_directory.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.quick-command-test." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": domain, "CFBundleExecutable": "QuickCommandSurfaceTests",
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
    }))
    try:
        for source in ("QuickCommandTemplateTests", "QuickCommandSurfaceTests"):
            if source == "QuickCommandSurfaceTests" and options.model_only:
                continue
            binary = binary_directory / source
            if source == "QuickCommandTemplateTests":
                test = temporary / "CompiledTemplateTests.swift"
                test.write_text((ROOT / "mac/tests/QuickCommandTemplateTests.swift").read_text().replace(
                    "import Foundation", "import Foundation\n@testable import zshell", 1))
            else:
                test = ROOT / "mac/tests/QuickCommandSurfaceTests.swift"
            subprocess.run(arguments + [str(test), "-o", str(binary)], cwd=ROOT, check=True)
            if options.compile_only:
                print(source + ": compiled")
                continue
            modes = ("model",) if source == "QuickCommandTemplateTests" else options.backend or ("alacritty", "ghostty")
            for mode in modes:
                home = temporary / mode
                (home / "fixture").mkdir(parents=True, exist_ok=True)
                (home / "tmp").mkdir(exist_ok=True)
                config = home / ".config/zshell-dev/config.toml"
                config.parent.mkdir(parents=True, exist_ok=True)
                config.write_text("ai.enabled = false\nquick-terminal.enabled = false\n"
                                  "terminal.preserve-sessions = false\nterminal.restore-history = false\n")
                environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
                environment.update({
                    "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                    "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
                    "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
                })
                if options.gui:
                    environment["ZSHELL_TEST_QUICK_COMMAND_GUI"] = "1"
                subprocess.run([str(binary), str(home / "fixture"), mode], cwd=ROOT,
                               env=environment, check=True, timeout=100)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
