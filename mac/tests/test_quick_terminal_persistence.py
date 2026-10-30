"""Exercise actual Quick Terminal windows, PTYs and independent GUI processes.

Build the Debug app, then run with ZSHELL_TEST_DERIVED_DATA pointing to its
DerivedData. By default every native window is kept offscreen and prohibited
from activation, keyboard focus and mouse capture. ZSHELL_QUICK_TEST_VISIBLE=1
enables visible acceptance only while the isolated GUI slot is available.
Existing settings, PTYs and app processes are never used. Test binaries and
state are removed.
"""

import os
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import time
import stat
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
if not LIBRARY.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} first.")

with tempfile.TemporaryDirectory(prefix="zshell-quick-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "QuickTerminalTests.app/Contents"
    binary = bundle / "MacOS/QuickTerminalTests"
    binary.parent.mkdir(parents=True)
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.quick-test." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
    }))
    (bundle / "Resources").symlink_to(APP / "Contents/Resources")
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
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
        str(LIBRARY), "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        str(ROOT / "mac/tests/QuickTerminalPersistenceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    scenarios = (
            ("local", ("local",)),
            ("modes", ("modes",)),
            ("relay", ("relay-reconnect",)),
            ("split", ("split-create", "split-skip", "split-restore-end-all")),
            ("persistent", ("preserve", "skip-reopen", "restore-end-all", "fresh-after-end-all")),
    )
    if os.environ.get("ZSHELL_QUICK_TEST_MENU_ONLY"):
        scenarios = (("menu", ("menu-lifecycle",)),)
    if selected := os.environ.get("ZSHELL_QUICK_TEST_SCENARIOS"):
        names = set(selected.split(","))
        if names - {name for name, _ in scenarios}:
            raise SystemExit(f"Unknown Quick Terminal scenarios: {selected}")
        scenarios = tuple(scenario for scenario in scenarios if scenario[0] in names)
    for backend in ("alacritty", "ghostty"):
        for scenario, phases in scenarios:
            home = temporary / backend / scenario
            home.mkdir(parents=True)
            (home / "tmp").mkdir()
            (home / "normal-shell-history").write_text("echo NORMAL_HISTORY_MARKER\n")
            # Ghostty's login launcher may reset HOME. ZDOTDIR survives login;
            # restore the isolated home before any shell startup/history work.
            startup = 'export HOME="$CFFIXED_USER_HOME"\nexport ZDOTDIR="$HOME"\nHISTFILE="$HOME/normal-shell-history"\nHISTSIZE=200\nSAVEHIST=200\n'
            (home / ".zshenv").write_text(startup)
            (home / ".zshrc").write_text(startup)
            (home / ".zprofile").write_text("")
            (home / ".zlogin").write_text("")
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                "ZDOTDIR": str(home),
                "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
                "ZSHELL_QUICK_TEST_OFFSCREEN": "0" if os.environ.get("ZSHELL_QUICK_TEST_VISIBLE") == "1" else "1",
                "TMPDIR": str(home / "tmp") + "/",
            })
            try:
                for phase in phases:
                    print(f"RUN {backend} {phase}", flush=True)
                    with subprocess.Popen([str(binary), backend, phase, str(home)], cwd=ROOT, env=environment) as fixture:
                        print(f"PROCESS backend={backend} phase={phase} pid={fixture.pid}", flush=True)
                        try:
                            code = fixture.wait(timeout=60)
                            if code != 0:
                                raise subprocess.CalledProcessError(code, fixture.args)
                        finally:
                            if fixture.poll() is None:
                                fixture.kill()
                                fixture.wait()
                            for socket in Path("/tmp").glob(f"zshell-{os.getuid()}-{fixture.pid}-*.sock"):
                                if stat.S_ISSOCK(socket.lstat().st_mode):
                                    socket.unlink()
            finally:
                command = [str(APP / "Contents/MacOS/zshell"), "+pty-mux"]
                listing = subprocess.run(command + ["list"], cwd=ROOT, env=environment,
                                         capture_output=True, text=True, timeout=10)
                if listing.returncode == 0:
                    for session in json.loads(listing.stdout):
                        subprocess.run(command + ["terminate", session["id"]], cwd=ROOT,
                                       env=environment, capture_output=True, timeout=10)
                    time.sleep(0.35)
                    subprocess.run(command + ["shutdown"], cwd=ROOT, env=environment,
                                   capture_output=True, timeout=10, check=True)
