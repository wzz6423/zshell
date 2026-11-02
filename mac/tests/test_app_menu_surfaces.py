"""Replay real app menu reconciliation in disposable, offscreen Debug fixtures."""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import struct
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def prepare_browser_sessions(home):
    chrome = home / "Library/Application Support/Google/Chrome/Default"
    sessions = chrome / "Sessions"
    sessions.mkdir(parents=True)
    (chrome / "History").touch()
    (chrome.parent / "Local State").write_text('{"profile":{"info_cache":{"Default":{"name":"Menu fixture"}}}}')

    def string(value, utf16=False):
        raw = value.encode("utf-16le" if utf16 else "utf-8")
        return struct.pack("<I", len(value) if utf16 else len(raw)) + raw + b"\0" * (-len(raw) % 4)

    def command(kind, payload):
        return struct.pack("<HB", len(payload) + 1, kind) + payload

    data = b"SNSS" + struct.pack("<I", 3)
    for index in range(24):
        identifier = index + 1
        navigation = (struct.pack("<III", 0, identifier, 0)
                      + string(f"http://127.0.0.1:1/menu-fixture/{index}") + string(f"Fixture {index}", True))
        data += (command(0, struct.pack("<II", 1, identifier)) + command(2, struct.pack("<II", identifier, index))
                 + command(6, navigation) + command(7, struct.pack("<II", identifier, 0)))
    (sessions / "Session_1").write_bytes(data)


parser = argparse.ArgumentParser()
parser.add_argument("--derived-data", type=Path, default=os.environ.get("ZSHELL_TEST_DERIVED_DATA"))
parser.add_argument("--work-dir", type=Path)
parser.add_argument("--backend", choices=("libghostty", "alacritty"))
options = parser.parse_args()
if not options.derived_data:
    parser.error("--derived-data 或 ZSHELL_TEST_DERIVED_DATA 必须指向已完成的 Debug 构建")
build = options.derived_data.resolve() / "Build"
products = build / "Products/Debug"
library = products / "zshell Debug.app/Contents/MacOS/zshell.debug.dylib"
if not library.is_file():
    parser.error(f"Debug 模块不存在：{library}")

with tempfile.TemporaryDirectory(prefix="zshell-app-menu-", dir=options.work_dir) as directory:
    temporary = Path(directory).resolve()
    binary = temporary / "app-menu-tests"
    arguments = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                 "-target", f"{platform.machine()}-apple-macos15.6",
                 "-module-cache-path", str(temporary / "modules"), "-I", str(products),
                 "-I", str(products / "include"), "-F", str(products)]
    for modulemap in (build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                  "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                  "-Xlinker", "-rpath", "-Xlinker", str(products),
                  "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                  str(ROOT / "mac/tests/AppMenuSurfaceTests.swift"),
                  str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(arguments, cwd=ROOT, check=True)
    for backend in (options.backend,) if options.backend else ("libghostty", "alacritty"):
        contents = temporary / f"MenuTests-{backend}.app/Contents"
        executable = contents / "MacOS/MenuTests"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binary, executable)
        domain = "sh.zshell.menu-test." + uuid.uuid4().hex
        info = plistlib.loads((library.parents[1] / "Info.plist").read_bytes())
        info.update(CFBundleIdentifier=domain, CFBundleExecutable=executable.name,
                    CFBundleName="Zshell Menu Test", CFBundleDisplayName="Zshell Menu Test",
                    LSBackgroundOnly=True, SUEnableAutomaticChecks=False)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "Resources").symlink_to(library.parents[1] / "Resources", target_is_directory=True)
        fixture = temporary / backend
        fixture.mkdir()
        prepare_browser_sessions(fixture)
        (fixture / "tmp").mkdir()
        configuration = fixture / ".config/zshell-dev/config.toml"
        configuration.parent.mkdir(parents=True)
        configuration.write_text(f'ai.enabled = false\nterminal.backend = "{backend}"\n'
                                 'terminal.preserve-sessions = false\nterminal.restore-history = false\n'
                                 'terminal.startup-program = "/bin/sleep 60"\nquick-terminal.enabled = false\n')
        for name in (".zshenv", ".zshrc", ".zprofile", ".zlogin"):
            (fixture / name).write_text("")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(CFFIXED_USER_HOME=str(fixture), ZDOTDIR=str(fixture), TMPDIR=str(fixture / "tmp"),
                           ZSHELL_PTY_MUX_DIRECTORY=str(fixture / "mux"), ZSHELL_SSH_AGENT_RESOLVED="1")
        process = subprocess.Popen([str(executable), backend, str(fixture)], cwd=temporary,
                                   env=environment, start_new_session=True)
        try:
            result = process.wait(timeout=20)
            if result:
                raise subprocess.CalledProcessError(result, process.args)
        finally:
            # 只清理本次测试的进程组，保留用户运行中的 Debug 与正式版实例。
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait()
            command_lines = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                          text=True, check=True).stdout.splitlines()
            for line in command_lines:
                fields = line.strip().split(maxsplit=1)
                if len(fields) == 2 and fields[1].startswith(str(executable) + " --pty-mux-"):
                    try:
                        os.kill(int(fields[0]), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            preferences = Path.home() / "Library/Preferences" / (domain + ".plist")
            if preferences.exists() and plistlib.loads(preferences.read_bytes()) == {}:
                preferences.unlink()
