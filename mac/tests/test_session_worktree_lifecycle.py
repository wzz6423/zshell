"""Run production session, split, close, and process-restart paths for both backends.

Build Debug first; ZSHELL_TEST_DERIVED_DATA selects an isolated build.
Project windows stay hidden; Quick Terminal windows remain offscreen without input capture.
Git fixtures, defaults, homes, binaries, and PTYs are disposable.
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
parser.add_argument("--backend", choices=("libghostty", "alacritty"))
options = parser.parse_args()
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running lifecycle tests.")

with tempfile.TemporaryDirectory(prefix="zshell-worktree-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    bundle = temporary / "Lifecycle Probe.app"
    binary = bundle / "Contents/MacOS/probe"
    binary.parent.mkdir(parents=True)
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
        str(ROOT / "mac/tests/SessionWorktreeLifecycleTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in ([options.backend] if options.backend else ("libghostty", "alacritty")):
        fixture = temporary / backend
        home = fixture / "home"
        repo = fixture / "repo"
        config = home / ".config/zshell-dev"
        config.mkdir(parents=True)
        (config / "config.toml").write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n')
        (home / ".zshrc").write_text("PROMPT='LIFECYCLE> '; RPROMPT=''; HISTFILE=/dev/null\n")
        repo.mkdir()
        with (bundle / "Contents/Info.plist").open("wb") as info:
            plistlib.dump({"CFBundleIdentifier": f"sh.zshell.test.worktree.{uuid.uuid4().hex}",
                          "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL"}, info)
        environment = {**os.environ, "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                       "ZSHELL_PTY_MUX_DIRECTORY": str(fixture / "pty"),
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        for key in ("ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN", "ZSHELL_AUTOMATION_TOKEN", "ZSHELL_AUTOMATION_SOCKET"):
            environment.pop(key, None)
        for command in (
            ["init", "-q", "--initial-branch=main"], ["config", "user.name", "Lifecycle Fixture"],
            ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", "/dev/null"], ["commit", "--allow-empty", "-qm", "base"],
        ):
            subprocess.run(["/usr/bin/git", *command], cwd=repo, env=environment, check=True)
        for phase in ("exercise", "restore"):
            subprocess.run([str(binary), phase, backend, str(fixture)], cwd=ROOT,
                           env=environment, check=True, timeout=90)
