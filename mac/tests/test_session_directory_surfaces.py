"""Verify session directory choices using real AppKit and PTYs on both backends.

Build Debug first and set ZSHELL_TEST_DERIVED_DATA to its directory. By default
all windows remain offscreen. Set ZSHELL_DIRECTORY_TEST_VISIBLE=1 only while
holding the GUI slot; ZSHELL_DIRECTORY_TEST_ARTIFACTS preserves screenshots.
Binaries, homes, PTYs, and preferences are removed after each run.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", choices=("libghostty", "alacritty"))
parser.add_argument("--empty-project", action="store_true", help="Check directory retention after the final session closes or exits and after restart.")
options = parser.parse_args()
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} first.")


def cleanup_private_mux(environment):
    directory = Path(environment["ZSHELL_PTY_MUX_DIRECTORY"])
    if not (directory / "daemon.lock").exists():
        return
    # The socket can survive daemon exit; the daemon holds this lock for its lifetime.
    with (directory / "daemon.lock").open("rb") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            pass
    mux = [str(APP / "Contents/MacOS/zshell"), "+pty-mux"]
    options = dict(env=environment, capture_output=True, text=True, timeout=10)
    listing = subprocess.run(mux + ["list"], check=True, **options)
    for session in json.loads(listing.stdout):
        if session["running"]:
            subprocess.run(mux + ["terminate", session["id"]], check=True, **options)
    deadline = time.monotonic() + 5
    while True:
        result = subprocess.run(mux + ["shutdown"], **options)
        if result.returncode == 0:
            return
        if "sessions_running" not in result.stderr or time.monotonic() >= deadline:
            raise RuntimeError("Cannot stop the disposable PTY mux: " + result.stderr)
        time.sleep(0.05)

with tempfile.TemporaryDirectory(prefix="zshell-directory-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "DirectoryProbe.app/Contents"
    binary = bundle / "MacOS/DirectoryProbe"
    binary.parent.mkdir(parents=True)
    bundle_identifier = "sh.zshell.directory-test." + uuid.uuid4().hex
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    info.update({
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    })
    (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
    (bundle / "Resources").symlink_to(APP / "Contents/Resources")
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
        str(LIBRARY), "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        str(ROOT / "mac/tests/TerminalSessionDirectorySurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(command, cwd=ROOT, check=True)
    try:
        for backend in ([options.backend] if options.backend else ("libghostty", "alacritty")):
            home = temporary / backend
            home.mkdir()
            (home / "tmp").mkdir()
            config = home / ".config/zshell-dev"
            config.mkdir(parents=True)
            (config / "config.toml").write_text('ai.enabled = false\nterminal.backend = "' + backend + '"\n')
            # Ghostty's login wrapper can reset HOME before the custom shell.
            startup = 'export HOME="$CFFIXED_USER_HOME"\nHISTFILE=/dev/null\n'
            (home / ".zshenv").write_text(startup + "PROMPT='DIRECTORY-READY> '; RPROMPT=''\n")
            (home / ".zshrc").write_text(startup + "PROMPT='DIRECTORY-READY> '; RPROMPT=''\n")
            (home / ".zprofile").write_text("")
            (home / ".zlogin").write_text("")
            results = home / "results"
            results.mkdir()
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty"),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                "ZSHELL_DIRECTORY_TEST_VISIBLE": os.environ.get("ZSHELL_DIRECTORY_TEST_VISIBLE", "0"),
                "ZSHELL_DIRECTORY_TEST_HOLD_SECONDS": os.environ.get("ZSHELL_DIRECTORY_TEST_HOLD_SECONDS", "10"),
                "ZSHELL_DIRECTORY_TEST_WORKSPACE": os.environ.get("ZSHELL_DIRECTORY_TEST_WORKSPACE", "0"),
            })
            print(f"RUN directory surfaces {backend}", flush=True)
            for phase in ("save", "restore") if options.empty_project else (None,):
                if phase:
                    environment["ZSHELL_DIRECTORY_TEST_EMPTY_PROJECT_PHASE"] = phase
                with subprocess.Popen([str(binary), backend, str(home), str(results)],
                                      cwd=ROOT, env=environment, start_new_session=True) as fixture:
                    print(f"PROCESS backend={backend} phase={phase} pid={fixture.pid}", flush=True)
                    try:
                        code = fixture.wait(timeout=240)
                        if code != 0:
                            raise subprocess.CalledProcessError(code, fixture.args)
                    finally:
                        if fixture.poll() is None:
                            os.killpg(fixture.pid, signal.SIGTERM)
                            try:
                                fixture.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(fixture.pid, signal.SIGKILL)
                                fixture.wait()
                        for socket in Path("/tmp").glob(f"zshell-{os.getuid()}-{fixture.pid}-*.sock"):
                            if stat.S_ISSOCK(socket.lstat().st_mode):
                                socket.unlink()
                        cleanup_private_mux(environment)
            if artifacts := os.environ.get("ZSHELL_DIRECTORY_TEST_ARTIFACTS"):
                destination = Path(artifacts)
                destination.mkdir(parents=True, exist_ok=True)
                for screenshot in results.glob("*.png"):
                    shutil.copy2(screenshot, destination / screenshot.name)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", bundle_identifier], capture_output=True, timeout=10)
        (Path.home() / "Library/Preferences" / f"{bundle_identifier}.plist").unlink(missing_ok=True)
