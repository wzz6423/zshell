"""Exercise terminal sharing previews through the compiled Debug app and real PTYs.

Set ZSHELL_TEST_DERIVED_DATA to the isolated build and acquire the shared build
and GUI lease first. File-picker responses are deterministic AppKit fixtures;
terminal buffers, background writes, errors and lifecycle paths are real.
A fixture-only temporary-directory getter keeps Foundation and native backend
captures under the same disposable HOME. Preferences, PTYs and captures are private.
"""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import tempfile
import uuid


root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", choices=("alacritty", "ghostty"))
options = parser.parse_args()
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", root / "mac/build/debug")).resolve() / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} first.")

with tempfile.TemporaryDirectory(prefix="zshell-redaction-tests-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    contents = temporary / "RedactionTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    domain = "sh.zshell.redaction-test." + uuid.uuid4().hex
    metadata = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    metadata.update({
        "CFBundleIdentifier": domain, "CFBundleExecutable": binary.name,
        "LSUIElement": True, "SUEnableAutomaticChecks": False,
    })
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "ZshellRedactionAcceptance",
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
        path = root / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(root / "mac/tests/TerminalRedactionSurfaceTests.swift"),
        str(root / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=root, check=True, timeout=120)
    for backend in (options.backend,) if options.backend else ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        (home / "tmp").mkdir()
        configuration = home / ".config/zshell-dev/config.toml"
        configuration.parent.mkdir(parents=True)
        configuration.write_text('ai.enabled = false\nterminal.preserve-sessions = false\n'
                                 'terminal.restore-history = false\nquick-terminal.enabled = false\n')
        for name in (".zshenv", ".zprofile", ".zlogin"):
            (home / name).write_text('export HOME="$CFFIXED_USER_HOME"\nHISTFILE=/dev/null\n')
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "TMPDIR": str(home / "tmp") + "/", "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_DATA_HOME": str(home / ".local/share"), "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
            "ZSHELL_SSH_AGENT_RESOLVED": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        })
        process = subprocess.Popen([str(binary), backend, str(home)], cwd=root, env=environment,
                                   start_new_session=True)
        try:
            if process.wait(timeout=120):
                raise subprocess.CalledProcessError(process.returncode, process.args)
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
            subprocess.run(["/usr/bin/defaults", "delete", domain],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
