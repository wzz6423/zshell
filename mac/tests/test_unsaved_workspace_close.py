"""Exercise production project, workspace-window and quit save confirmations.

Build Debug first; ZSHELL_TEST_DERIVED_DATA selects an isolated build.
Both terminal backends run with disposable PTYs, homes, Git fixtures and
screen-hidden AppKit windows. Test binaries, caches and preferences are removed.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", choices=("libghostty", "alacritty"))
options = parser.parse_args()
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running unsaved workspace close tests.")

with tempfile.TemporaryDirectory(prefix="zshell-unsaved-close-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "Unsaved Close Probe.app/Contents"
    binary = bundle / "MacOS/probe"
    binary.parent.mkdir(parents=True)
    domain = f"sh.zshell.test.unsaved-close.{uuid.uuid4().hex}"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info.update(CFBundleIdentifier=domain, CFBundleExecutable="probe",
                CFBundleName="Unsaved Close Probe", CFBundleDisplayName="Unsaved Close Probe",
                CFBundleDevelopmentRegion="en", LSBackgroundOnly=True, SUEnableAutomaticChecks=False)
    (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
    (bundle / "Resources").symlink_to(app / "Contents/Resources")
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-target", f"{platform.machine()}-apple-macos15.6",
               "-module-cache-path", str(temporary / "ModuleCache"),
               "-I", str(products), "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                "-Xlinker", "-rpath", "-Xlinker", str(products),
                "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                str(ROOT / "mac/tests/UnsavedWorkspaceCloseTests.swift"),
                str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(command, cwd=ROOT, check=True)
    for backend in ([options.backend] if options.backend else ("libghostty", "alacritty")):
        fixture = temporary / backend
        home = fixture / "home"
        repo = fixture / "repo"
        config = home / ".config/zshell-dev"
        config.mkdir(parents=True)
        repo.mkdir()
        (home / "tmp").mkdir()
        (config / "config.toml").write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n'
                                           'terminal.preserve-sessions = true\nterminal.restore-history = false\n'
                                           'terminal.startup-program = "/bin/sleep 240"\nquick-terminal.enabled = false\n')
        startup = 'export HOME="$CFFIXED_USER_HOME"\nexport ZDOTDIR="$HOME"\nHISTFILE=/dev/null\n'
        for name in (".zshenv", ".zshrc", ".zprofile", ".zlogin"):
            (home / name).write_text(startup)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           TMPDIR=str(home / "tmp"), ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"),
                           ZSHELL_SSH_AGENT_RESOLVED="1", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        for arguments in (
            ["init", "-q", "--initial-branch=main"], ["config", "user.name", "Close Fixture"],
            ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"], ["commit", "--allow-empty", "-qm", "base"],
        ):
            subprocess.run(["/usr/bin/git", *arguments], cwd=repo, env=environment, check=True)
        process = subprocess.Popen([str(binary), backend, str(repo)], cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, env=environment, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=75)
            print(output, end="", flush=True)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, process.args)
            summaries = re.findall(rf"^UNSAVED_WORKSPACE_CLOSE_SUCCESS backend={backend} checks=(\d+)$", output, re.MULTILINE)
            phases = re.findall(rf"^UNSAVED_PHASE_COMPLETE backend={backend} phase=(\w+)$", output, re.MULTILINE)
            if len(summaries) != 1 or int(summaries[0]) != 39 or phases != ["project", "worktree", "window", "quit"]:
                raise RuntimeError(f"The {backend} probe exited without completing all project/window/quit checks.")
        finally:
            # The fixture owns this process group and this PTY mux directory.
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
                    subprocess.run(mux + ["terminate", session["id"]], cwd=ROOT,
                                   env=environment, capture_output=True, timeout=10)
                subprocess.run(mux + ["shutdown"], cwd=ROOT, env=environment, capture_output=True, timeout=10)
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
