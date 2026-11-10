"""Verify unchanged terminal history saves against production Swift code.

The default storage probe needs no app build. Use --surfaces after an isolated
Debug build to exercise autosave, legacy restore, pruning and last-window reopen
with both terminal backends. All binaries, homes and module caches are removed.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--surfaces", action="store_true")
parser.add_argument("--source-ref", help="Use an earlier production history store for the storage probe")
options = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="zshell-history-persistence-", dir="/tmp") as directory:
    temporary = Path(directory).resolve()
    binary = temporary / "history-tests"
    command = [
        "xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-D", "DEBUG",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-target", f"{platform.machine()}-apple-macos15.6",
    ]
    if options.surfaces:
        build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
        products = build / "Products/Debug"
        bundle = products / "zshell Debug.app"
        library = bundle / "Contents/MacOS/zshell.debug.dylib"
        if not library.is_file():
            raise SystemExit(f"Build the Debug app in {build.parent} first.")
        command += ["-I", str(products), "-I", str(products / "include"), "-F", str(products)]
        for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
            command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
        for include in (
            "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
            "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
        ):
            path = ROOT / "mac/Vendor" / include
            command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
        command += [
            "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
            "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
            "-Xlinker", "-rpath", "-Xlinker", str(products),
            "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
            str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"),
        ]
        modes = ("alacritty", "ghostty")
    else:
        source = ROOT / "mac/zshell/TerminalHistory.swift"
        if options.source_ref:
            source = temporary / "TerminalHistory.swift"
            source.write_bytes(subprocess.check_output(
                ["git", "show", f"{options.source_ref}:mac/zshell/TerminalHistory.swift"], cwd=ROOT))
        support = temporary / "Surface.swift"
        support.write_text("""import Foundation
@MainActor protocol TerminalBackendSurface {
    func exportScreenFile() -> String?
    func exportScrollbackFile() -> String?
}
""")
        command += [
            "-D", "TERMINAL_HISTORY_STORE_PROBE", "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-warnings-as-errors",
            str(support), str(source),
        ]
        modes = ("store",)
    command += [str(ROOT / "mac/tests/TerminalHistoryPersistenceTests.swift"), "-o", str(binary)]
    subprocess.run(command, cwd=ROOT, check=True, timeout=120)
    for mode in modes:
        home = temporary / mode
        home.mkdir()
        (home / "tmp").mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           TMPDIR=str(home / "tmp"), ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"),
                           ZSHELL_SSH_AGENT_RESOLVED="1", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        executable = binary
        domain = None
        if options.surfaces:
            contents = temporary / f"History-{mode}.app/Contents"
            executable = contents / "MacOS/HistoryTests"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(binary.read_bytes())
            executable.chmod(0o700)
            domain = "sh.zshell.history-persistence-test." + uuid.uuid4().hex
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": domain, "CFBundleExecutable": executable.name,
                "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
            }))
            (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
            for name in (".zshenv", ".zshrc", ".zprofile", ".zlogin"):
                (home / name).write_text('export HOME="$CFFIXED_USER_HOME"\nexport ZDOTDIR="$HOME"\nHISTFILE=/dev/null\n')
        process = subprocess.Popen([str(executable), mode, str(home)], cwd=ROOT, env=environment,
                                   start_new_session=True)
        try:
            if process.wait(timeout=90):
                raise subprocess.CalledProcessError(process.returncode, process.args)
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
            if domain:
                mux = [str(bundle / "Contents/MacOS/zshell"), "+pty-mux"]
                listing = subprocess.run(mux + ["list"], cwd=ROOT, env=environment,
                                         capture_output=True, text=True, timeout=10)
                if listing.returncode == 0:
                    for session in json.loads(listing.stdout):
                        subprocess.run(mux + ["terminate", session["id"]], cwd=ROOT, env=environment,
                                       capture_output=True, timeout=10)
                    subprocess.run(mux + ["shutdown"], cwd=ROOT, env=environment, capture_output=True, timeout=10)
                subprocess.run(["defaults", "delete", domain], cwd=ROOT, check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
