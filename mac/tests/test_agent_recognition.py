"""Exercise compiled agent rules, real PTYs, and offscreen AppKit controls.

Build Debug first and set ZSHELL_TEST_DERIVED_DATA. Every fixture, preference,
provider process, and window is disposable; existing apps are not touched.
"""

import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import subprocess
import tempfile
import uuid


root = Path(__file__).resolve().parents[2]
build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app/Contents"
library = app / "MacOS/zshell.debug.dylib"
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running recognition tests.")

fixture = r'''
import json, os, select, signal, sys, tty
from pathlib import Path
root = Path(sys.argv[1]); root.mkdir(exist_ok=True)
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
if os.getpid() != os.getpgrp(): os.setpgid(0, 0)
os.tcsetpgrp(0, os.getpgrp())
tty.setraw(0)
alternate = True
os.write(1, b"\x1b[?1049h")
def draw(value):
    global alternate
    if value.get("alternate", True) != alternate:
        alternate = value.get("alternate", True)
        os.write(1, b"\x1b[?1049h" if alternate else b"\x1b[?1049l")
    columns, rows = os.get_terminal_size()
    if value.get("history"):
        os.write(1, ("old hopping…\r\n" * 200 + "clean row\r\n" * rows).encode())
    output = "\x1b[2J\x1b[H"
    for index, line in enumerate(value.get("lines", ["hopping…"])):
        output += f"\x1b[{max(1, rows-4+index)};1H" + line
    os.write(1, output.encode())
draw({})
(root / "pid.json").write_text(json.dumps({"pid": os.getpid()}))
def stop(*args):
    os.write(1, b"\x1b[?1049l")
    raise SystemExit
signal.signal(signal.SIGTERM, stop)
while True:
    command = root / "command.json"
    if command.exists():
        value = json.loads(command.read_text()); command.unlink()
        if value.get("exit"): stop()
        draw(value)
    if select.select([0], [], [], .01)[0]:
        if not os.read(0, 4096): break
'''

with tempfile.TemporaryDirectory(prefix="zshell-recognition-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "AgentRecognitionProductionProbe",
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
        path = root / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    arguments += [
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(root / "mac/Vendor/tree-sitter/lib/include"), str(library),
        "-Xlinker", "-rpath", "-Xlinker", str(products),
        "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
    ]
    sources = {
        "model": ["AgentRecognitionRulesTests.swift"],
        "surfaces": ["AgentRecognitionSurfaceTests.swift", "QuickTerminalOffscreen.swift"],
        "appkit": ["AgentRecognitionAppKitTests.swift", "QuickTerminalOffscreen.swift"],
    }
    modes = os.environ.get("ZSHELL_TEST_RECOGNITION_MODES", "model,alacritty,ghostty,appkit").split(",")
    binaries = {}
    for mode in modes:
        source = "surfaces" if mode in ("alacritty", "ghostty") else mode
        if source in binaries:
            continue
        contents = temporary / f"RecognitionTests-{source}.app/Contents"
        binary = contents / "MacOS/zshell"
        binary.parent.mkdir(parents=True)
        (contents / "Resources").symlink_to(app / "Resources", target_is_directory=True)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info.update({
            "CFBundleIdentifier": "sh.zshell.recognition-tests." + source + "." + uuid.uuid4().hex,
            "CFBundleExecutable": "zshell", "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
        })
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(arguments + [str(root / "mac/tests" / name) for name in sources[source]]
                       + ["-o", str(binary)], check=True, cwd=root)
        binaries[source] = binary
    for mode in modes:
        source = "surfaces" if mode in ("alacritty", "ghostty") else mode
        binary = binaries[source]
        home = temporary / mode
        home.mkdir()
        for command in ("frog-cli", "claude-wrapper"):
            (home / f"{command}.py").write_text(fixture)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("ZSHELL_") and key not in {
                           "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME",
                           "XDG_DATA_HOME", "XDG_STATE_HOME", "ZDOTDIR", "OPENCODE_CONFIG_DIR",
                       }}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"),
        })
        try:
            subprocess.run([str(binary), mode, str(home)], cwd=root, env=environment,
                           check=True, timeout=120)
        finally:
            for record in home.glob("*/pid.json"):
                pid = json.loads(record.read_text())["pid"]
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                         capture_output=True, text=True).stdout
                if str(home) in command and any(name in command for name in ("frog-cli.py", "claude-wrapper.py")):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            domain = plistlib.loads((binary.parents[1] / "Info.plist").read_bytes())["CFBundleIdentifier"]
            subprocess.run(["/usr/bin/defaults", "delete", domain],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
