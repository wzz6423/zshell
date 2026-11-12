"""Replay native scroll events through both production backends and real PTYs.

ZSHELL_TEST_DERIVED_DATA=/tmp/scroll-build python3 mac/tests/test_terminal_scroll_surfaces.py
Add --backend ghostty --hold to inspect the isolated terminal and settings.
Add --layout to exercise the native settings across all languages and widths.
"""

import os
import argparse
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import uuid


root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", choices=("alacritty", "ghostty"))
parser.add_argument("--hold", action="store_true", help="Show an isolated terminal and settings until interrupted")
parser.add_argument("--layout", action="store_true", help="Validate all localized native scrolling rows")
options = parser.parse_args()
build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running the surface probe.")

with tempfile.TemporaryDirectory(prefix="zshell-scroll-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "ScrollTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.scroll-tests." + uuid.uuid4().hex
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    info.update(CFBundleIdentifier=domain, CFBundleExecutable=binary.name, LSUIElement=not options.hold)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "TerminalScrollSurfaceProbe", "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(products), "-I", str(products / "include"), "-F", str(products),
    ]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = root / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(root / "mac/tests/TerminalScrollSurfaceTests.swift"), "-o", str(binary),
    ]
    subprocess.run(command, cwd=root, check=True)
    try:
        for backend in (options.backend,) if options.backend else ("alacritty", "ghostty"):
            home = temporary / backend
            home.mkdir()
            configuration = home / ".config/zshell-dev/config.toml"
            configuration.parent.mkdir(parents=True)
            configuration.write_text('ai.enabled = false\nquick-terminal.enabled = false\n'
                                     'git.proxy-enabled = false\nterminal.preserve-sessions = false\n')
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                               ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1",
                               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
            if options.hold:
                environment["ZSHELL_SCROLL_TEST_HOLD"] = "1"
            if options.layout:
                environment["ZSHELL_SCROLL_TEST_LAYOUT"] = "1"
            process = subprocess.Popen([str(binary), backend, str(home), sys.executable,
                                        str(root / "mac/tests/fixtures/terminal-scroll.py")], cwd=root,
                                       env=environment, start_new_session=True)
            try:
                result = process.wait(timeout=None if options.hold else 90)
                if result:
                    raise subprocess.CalledProcessError(result, process.args)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
    finally:
        subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
