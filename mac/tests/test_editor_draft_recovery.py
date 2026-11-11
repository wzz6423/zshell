"""Restart the production editor after SIGKILL and exercise its real recovery/save paths.

Build Debug first; ZSHELL_TEST_DERIVED_DATA selects an isolated build.
Both backend settings run with disposable homes, bundles and Git fixtures.
"""
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import threading
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app"
library = app / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running draft recovery tests.")

with tempfile.TemporaryDirectory(prefix="zshell-draft-test-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "Editor Draft Probe.app/Contents"
    binary = bundle / "MacOS/probe"
    binary.parent.mkdir(parents=True)
    domain = f"sh.zshell.test.editor-draft.{uuid.uuid4().hex}"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    info.update(CFBundleIdentifier=domain, CFBundleExecutable="probe", CFBundleDevelopmentRegion="en",
                CFBundleName="Editor Draft Probe", LSBackgroundOnly=True, SUEnableAutomaticChecks=False)
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
                str(ROOT / "mac/tests/EditorDraftRecoveryTests.swift"),
                str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(command, cwd=ROOT, check=True)
    environments = []
    domains = []
    try:
        for backend, normal_exit in (("libghostty", False), ("alacritty", False),
                                     ("libghostty", True), ("alacritty", True)):
            mode = "normal" if normal_exit else "crash"
            fixture = temporary / f"{backend}-{mode}"
            info["CFBundleIdentifier"] = f"{domain}.{backend}.{mode}"
            domains.append(info["CFBundleIdentifier"])
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            home = fixture / "home"
            repo = fixture / "repo"
            config = home / ".config/zshell-dev"
            config.mkdir(parents=True)
            repo.mkdir()
            (home / "tmp").mkdir()
            (config / "config.toml").write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n'
                                               'terminal.restore-history = false\nterminal.preserve-sessions = false\n'
                                               'terminal.startup-program = "/bin/sleep 120"\nquick-terminal.enabled = false\n')
            env = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home), TMPDIR=str(home / "tmp"),
                       ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1",
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
            environments.append(env)
            subprocess.run(["/usr/bin/git", "init", "-q", "--initial-branch=main"], cwd=repo, env=env, check=True)
            writer = subprocess.Popen([str(binary), "normal-write" if normal_exit else "write", str(repo)], env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, text=True, start_new_session=True)
            watchdog = threading.Timer(60, lambda: os.killpg(writer.pid, signal.SIGKILL) if writer.poll() is None else None)
            watchdog.start()
            reached_backup = False
            try:
                for line in writer.stdout:
                    print(f"{backend}-{mode}: {line}", end="", flush=True)
                    if line.strip() == "EDITOR_DRAFT_READY_FOR_CRASH":
                        reached_backup = True
                        os.killpg(writer.pid, signal.SIGKILL)
                        break
                result = writer.wait(timeout=15)
                if normal_exit and result != 0:
                    raise RuntimeError(f"Normal writer failed: {result}")
                if not normal_exit and (result != -signal.SIGKILL or not reached_backup):
                    raise RuntimeError(f"Writer did not reach its durable backup boundary: {result}")
            finally:
                watchdog.cancel()
                if writer.poll() is None:
                    os.killpg(writer.pid, signal.SIGKILL)
                    writer.wait()
            (repo / "renamed.txt").write_text("external file version")
            (repo / "diff.txt").write_text("external diff version")
            (repo / "deleted.txt").unlink()
            replacement = repo / "other-symlink-target.txt"
            replacement.write_text("different target")
            (repo / "linked.txt").unlink()
            (repo / "linked.txt").symlink_to(replacement)
            for phase in (("restore",) if normal_exit else ("restore", "boundaries", "workspace")):
                process = subprocess.run([str(binary), phase, str(repo)], env=env, capture_output=True,
                                         text=True, cwd=ROOT, timeout=75)
                print(process.stdout, end="", flush=True)
                if process.stderr:
                    print(process.stderr, end="", flush=True)
                process.check_returncode()
                if f"EDITOR_DRAFT_SUCCESS phase={phase}" not in process.stdout:
                    raise RuntimeError(f"The {backend} {phase} probe did not finish")
    finally:
        mux = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]
        for env in environments:
            listing = subprocess.run(mux + ["list"], env=env, capture_output=True, text=True, timeout=10)
            if listing.returncode == 0:
                for session in json.loads(listing.stdout):
                    subprocess.run(mux + ["terminate", session["id"]], env=env, capture_output=True, timeout=10)
                subprocess.run(mux + ["shutdown"], env=env, capture_output=True, timeout=10)
        for cleanup_domain in domains:
            subprocess.run(["defaults", "delete", cleanup_domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
