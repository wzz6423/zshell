"""Exercise local Agent interrupts through both compiled Debug terminal views.

Set ZSHELL_TEST_DERIVED_DATA to an isolated Debug build. The provider, PTYs,
application, HOME and preferences are disposable; no account or live app is used.
"""

import os
import json
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
    raise SystemExit(f"Build the Debug app in {build.parent} before running interrupt surface tests.")

with tempfile.TemporaryDirectory(prefix="zshell-interrupt-surfaces-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "InterruptTests.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Resources", target_is_directory=True)
    domain = "sh.zshell.interrupt-tests." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": domain, "CFBundleExecutable": "zshell",
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-name", "AgentInterruptSurfaceProbe",
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
        "-o", str(binary), str(root / "mac/tests/AgentInterruptSurfaceTests.swift"),
    ]
    subprocess.run(arguments, cwd=root, check=True)
    for backend in ("alacritty", "ghostty"):
        home = temporary / backend
        home.mkdir()
        fixture = home / "claude.py"
        fixture.write_text(r'''
import json, os, select, signal, sys, tty
from pathlib import Path
root = Path(sys.argv[1])
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
if os.getpid() != os.getpgrp(): os.setpgid(0, 0)
os.tcsetpgrp(0, os.getpgrp())
tty.setraw(0)
busy = False
restore_on_interrupt = True
def draw():
    columns, rows = os.get_terminal_size()
    output = "\x1b[2J\x1b[H"
    lines = ["─" * columns, "❯ restored prompt", "─" * columns,
             "  esc to interrupt" if busy else "  ⏵⏵ bypass permissions on"]
    for index, line in enumerate(lines): output += f"\x1b[{rows-3+index};1H" + line
    output += f"\x1b[{rows-2};18H"
    os.write(1, output.encode())
def state(osc=False):
    pending = root / "state.tmp"
    pending.write_text(json.dumps({"pid": os.getpid(), "busy": busy, "oscIdle": osc}))
    pending.replace(root / "state.json")
draw(); state()
while True:
    command = root / "command.json"
    if command.exists():
        value = json.loads(command.read_text()); command.unlink()
        busy = value["busy"]
        restore_on_interrupt = value.get("restore", True)
        draw(); state()
    if select.select([0], [], [], .01)[0]:
        data = os.read(0, 4096)
        if not data: break
        with (root / "input.bin").open("ab") as output: output.write(data)
        if restore_on_interrupt and (b"\x1b" in data or b"\x03" in data):
            busy = False
            os.write(1, b"\x1b]7501;state=idle:app=claude-code\x07")
            draw(); state(osc=True)
''')
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({
            "HOME": str(home), "CFFIXED_USER_HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
        })
        try:
            subprocess.run([str(binary), backend, str(home)], cwd=root, env=environment,
                           check=True, timeout=90)
        finally:
            state = home / "state.json"
            if state.exists():
                pid = json.loads(state.read_text())["pid"]
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                         capture_output=True, text=True).stdout
                if str(fixture) in command:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            subprocess.run(["/usr/bin/defaults", "delete", domain],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
