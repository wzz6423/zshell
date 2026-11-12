"""Test the built Settings window on both backends using an isolated stand-in CLI.

--prepare-visible OUTPUT copies launchable probe bundles and a launcher for
manual review. Automatic runs leave no binaries, homes or CLI processes.
"""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]).resolve() / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
parser = argparse.ArgumentParser()
parser.add_argument("--prepare-visible", type=Path)
arguments = parser.parse_args()
if not LIBRARY.is_file():
    raise SystemExit("An isolated Debug build is required")

FAKE = '''#!PYTHON
import json
from pathlib import Path
import os
import sys
root = Path(__file__).resolve().parent.parent
with (root / 'cli-starts').open('a') as file:
    file.write(str(os.getpid()) + '\\n')
for line in sys.stdin:
    value = json.loads(line)
    if value.get('id') == 1:
        print(json.dumps({'id': 1, 'result': {}}), flush=True)
    if value.get('id') == 2:
        print(json.dumps({'id': 2, 'error': {'code': -32600, 'message': 'authentication required'}}), flush=True)
        break
'''

with tempfile.TemporaryDirectory(prefix="zshell-usage-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    binary = temporary / "UsageSettingsProbe"
    args = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(temporary / "modules"),
            "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS)]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        args += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        args += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    args += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
             "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(LIBRARY),
             "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
             "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
             str(ROOT / "mac/tests/AgentUsageSettingsSurfaceTests.swift"),
             str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(args, cwd=ROOT, check=True)
    destination = arguments.prepare_visible.resolve() if arguments.prepare_visible else None
    if destination:
        if destination.exists():
            raise SystemExit("Visible fixture destination must be new")
        destination.mkdir(parents=True)
    for backend in ("alacritty", "ghostty"):
        base = destination if destination else temporary
        home = base / backend
        home.mkdir()
        (home / "tmp").mkdir()
        (home / "bin").mkdir()
        (home / "usage").mkdir()
        config = home / ".config/zshell-dev/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text('ai.enabled = false\nai.usage-enabled = false\nterminal.restore-history = false\nterminal.preserve-sessions = false\n')
        (home / ".zshenv").write_text('export HOME="$CFFIXED_USER_HOME"\n')
        for name in (".zshrc", ".zprofile", ".zlogin"):
            (home / name).write_text("")
        cli = home / "bin/codex"
        cli.write_text(FAKE.replace("#!PYTHON", "#!" + str(Path(os.sys.executable).resolve()), 1))
        cli.chmod(0o700)
        bundle = base / f"Agent Usage {backend}.app/Contents"
        executable = bundle / "MacOS/AgentUsageSettings"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        (bundle / "Resources").symlink_to(APP / "Contents/Resources", target_is_directory=True)
        domain = "sh.zshell.usage-settings." + uuid.uuid4().hex
        info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
        info.update({
            "CFBundleIdentifier": domain, "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL", "CFBundleName": "Agent Usage Settings", "LSUIElement": not bool(destination),
            "SUEnableAutomaticChecks": False,
        })
        info.pop("NSServices", None)
        (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
        environment = {}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
                            "TMPDIR": str(home / "tmp")+"/", "PATH": str(home / "bin")+":/usr/bin:/bin:/usr/sbin:/sbin",
                            "CODEX_HOME": str(home / "codex"), "CLAUDE_CONFIG_DIR": str(home / "claude"),
                            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "mux"),
                            "ZSHELL_CLAUDE_USAGE_FILE": str(home / "usage/claude.json")})
        if destination:
            launcher = base / f"launch-{backend}.py"
            payload = {"executable": str(executable), "backend": backend, "home": str(home), "environment": environment}
            launcher.write_text("#!/usr/bin/env python3\nimport json, os\nsettings=json.loads("+repr(__import__('json').dumps(payload))+")\nos.execve(settings['executable'],[settings['executable'],settings['backend'],settings['home'],'--visible'],settings['environment'])\n")
            launcher.chmod(0o700)
        else:
            try:
                subprocess.run([str(executable), backend, str(home)], env=environment, cwd=ROOT, check=True, timeout=50)
            finally:
                subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if destination:
        print(f"Visible production Settings launchers: {destination}")
