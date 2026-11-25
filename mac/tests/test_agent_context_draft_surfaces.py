"""Run the production AppKit draft controller with both native PTY backends.

Build Debug and acquire the shared GUI lease before running --derived-data.
The fixture uses disposable preferences, HOME, shells, and an agent byte recorder.
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
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
parser.add_argument("--compile-only", action="store_true")
options = parser.parse_args()
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit("Build Debug in the supplied DerivedData first")

with tempfile.TemporaryDirectory(prefix="zshell-agent-draft-tests-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    contents = temporary / "AgentDraftProbe.app/Contents"
    binary = contents / "MacOS/AgentDraftProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.agent-draft-test." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
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
        str(ROOT / "mac/tests/AgentContextDraftSurfaceTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    if not options.compile_only:
        try:
            for backend in options.backend or ("alacritty", "ghostty"):
                home = temporary / backend
                (home / "fixture").mkdir(parents=True)
                (home / "tmp").mkdir()
                config = home / ".config/zshell-dev/config.toml"
                config.parent.mkdir(parents=True)
                config.write_text('ai.enabled = false\nquick-terminal.enabled = false\n'
                                  'terminal.preserve-sessions = false\nterminal.restore-history = false\n')
                environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
                environment.update({
                    "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                    "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
                    "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
                })
                subprocess.run([str(binary), str(home / "fixture"), backend], cwd=ROOT,
                               env=environment, check=True, timeout=120)
        finally:
            subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
