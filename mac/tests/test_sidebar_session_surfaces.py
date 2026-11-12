"""Exercise native pane closes and sidebar blank creation against both terminal backends.

Build Debug first, then pass --derived-data for an isolated app build. The
fixture reuses the app resources, stays offscreen and removes its disposable
homes, terminal processes, executable and module cache when it completes.
"""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import signal
import json
import re
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path,
    default=Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")))
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
options = parser.parse_args()
build = options.derived_data / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {options.derived_data} before running the sidebar probe")

with tempfile.TemporaryDirectory(prefix="zshell-sidebar-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "SidebarFixture.app/Contents"
    executable = contents / "MacOS/sidebar-probe"
    executable.parent.mkdir(parents=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info.update({"CFBundleIdentifier": "sh.zshell.sidebar-fixture." + uuid.uuid4().hex,
                 "CFBundleExecutable": executable.name, "LSBackgroundOnly": True})
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "Resources").symlink_to(app / "Contents/Resources", target_is_directory=True)
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
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent), "-o", str(executable),
        str(ROOT / "mac/tests/SidebarSessionSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift")]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in options.backend or ("ghostty", "alacritty"):
        # Each backend must start with its own session-snapshot preference domain.
        domain = "sh.zshell.pane-close-fixture." + uuid.uuid4().hex
        info["CFBundleIdentifier"] = domain
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        home = temporary / backend / "home"
        home.mkdir(parents=True)
        config = home / ".config/zshell-dev"
        config.mkdir(parents=True)
        (config / "config.toml").write_text("ai.enabled = false\n")
        files = temporary / backend / "temporary"
        files.mkdir(mode=0o700)
        environment = {key: value for key, value in os.environ.items()
            if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(files),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"), "ZSHELL_SSH_AGENT_RESOLVED": "1",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
        process = subprocess.Popen([str(executable), backend], cwd=ROOT, env=environment, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            output, _ = process.communicate(timeout=150)
            print(output, end="", flush=True)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, process.args)
            summaries = re.findall(rf"^PANE_CLOSE {backend} (\d+) passed$", output, re.MULTILINE)
            if len(summaries) != 1 or int(summaries[0]) < 1:
                raise RuntimeError(f"The {backend} fixture exited before all pane-close checks completed")
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
            mux = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]
            listing = subprocess.run(mux + ["list"], cwd=ROOT, env=environment,
                capture_output=True, text=True, timeout=10)
            if listing.returncode == 0:
                for session in json.loads(listing.stdout):
                    subprocess.run(mux + ["terminate", session["id"]], cwd=ROOT, env=environment,
                        capture_output=True, timeout=10)
                subprocess.run(mux + ["shutdown"], cwd=ROOT, env=environment, capture_output=True, timeout=10)
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
