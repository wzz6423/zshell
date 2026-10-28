"""Verify production history, private control sockets, and both terminal backends.

Build Debug first and set ZSHELL_TEST_DERIVED_DATA to that isolated build.
Provider processes, HOME, settings, sockets, PTY mux, and binaries are disposable.
The AppKit windows remain hidden and never claim a visible GUI lease.
"""
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
import uuid
import json
import time


root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", root / "mac/build/debug")) / "Build"
products = build / "Products/Debug"
bundle = products / "zshell Debug.app"
library = bundle / "Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running history tests.")

with tempfile.TemporaryDirectory(prefix="zshell-history-tests-", dir="/tmp") as temporary:
    directory = Path(temporary)
    contents = directory / "HistoryTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "sh.zshell.history-tests." + uuid.uuid4().hex,
        "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL",
        "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "ZshellConversationHistoryTests",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(directory / "ModuleCache"),
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
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"),
        str(library), "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(root / "mac/tests/AgentConversationHistoryTests.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=root, check=True)
    provider_bin = directory / "providers"
    provider_bin.mkdir()
    for provider in ("claude", "codex", "pi", "opencode"):
        target = provider_bin / provider
        shutil.copyfile(root / "mac/tests/fixtures/agent-conversation.py", target)
        target.write_text("#!/usr/bin/python3\n" + target.read_text())
        target.chmod(0o700)
    modes = (os.environ["ZSHELL_TEST_HISTORY_MODE"],) if "ZSHELL_TEST_HISTORY_MODE" in os.environ else ("store", "alacritty", "ghostty")
    for mode in modes:
        home = directory / mode
        home.mkdir()
        mode_contents = directory / f"HistoryTests-{mode}.app/Contents"
        mode_binary = mode_contents / "MacOS/zshell"
        mode_binary.parent.mkdir(parents=True)
        shutil.copy2(binary, mode_binary)
        (mode_contents / "Resources").symlink_to(bundle / "Contents/Resources", target_is_directory=True)
        mode_bundle_id = "sh.zshell.history-tests." + mode + "." + uuid.uuid4().hex
        (mode_contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": mode_bundle_id,
            "CFBundleExecutable": mode_binary.name, "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
        }))
        fixture_root = home / "fixture"
        fixture_root.mkdir()
        (home / ".zshrc").write_text(f"export PATH='{provider_bin}':$PATH\nunset HISTFILE\n")
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("ZSHELL_") and key not in {
                           "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR",
                           "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "ZDOTDIR",
                           "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG",
                       }}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "PATH": str(provider_bin) + ":" + environment.get("PATH", "/usr/bin:/bin"),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
            "HISTORY_TEST_ROOT": str(fixture_root),
        })
        try:
            subprocess.run([str(mode_binary), mode, str(provider_bin)], cwd=root,
                           env=environment, check=True, timeout=180)
        finally:
            for path in fixture_root.glob("launch-*.json"):
                (fixture_root / path.name.replace("launch-", "stop-").removesuffix(".json")).touch()
            time.sleep(0.1)
            for path in fixture_root.glob("launch-*.json"):
                pid = json.loads(path.read_text())["pid"]
                command = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                                         text=True, capture_output=True, check=False).stdout.strip()
                if not command or not any(str(provider_bin / provider) in command.split()
                                          for provider in ("claude", "codex", "pi", "opencode")):
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if (home / "pty-mux/control.sock").exists():
                subprocess.run([str(mode_binary), "+pty-mux", "shutdown"], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            subprocess.run(["/usr/bin/defaults", "delete", mode_bundle_id],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
