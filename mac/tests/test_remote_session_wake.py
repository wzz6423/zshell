"""Verify wake recovery through production relay, OpenSSH, server and both surfaces.

The fixture reuses the browser test's isolated sshd. A transparent bridge can
withhold one old pong while the real server continues to own the same PTY.
No machine sleep, personal SSH files or existing server state is changed.
"""

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_browser_remote_routing import Fixture, ROOT


BRIDGE = r'''
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import threading

server, state, directory, *arguments = sys.argv[1:]
if arguments != ["bridge"]:
    os.execv(server, [server, "--state", state, *arguments])
process = subprocess.Popen([server, "bridge", "--state", state], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
identity = {}
events = os.open(str(Path(directory) / "events.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)

def event(name, kind, **details):
    value = {"event": name, "kind": kind, "bridgePID": os.getpid(), **identity, **details}
    os.write(events, json.dumps(value).encode() + b"\n")

def exactly(stream, count):
    data = b""
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data

def frame(stream):
    prefix = exactly(stream, 4)
    if prefix is None:
        return None
    count = struct.unpack("!I", prefix)[0]
    if not 0 < count <= 256 * 1024:
        raise RuntimeError("Invalid production frame")
    payload = exactly(stream, count)
    return None if payload is None else (prefix + payload, json.loads(payload))

def fault():
    try:
        value = json.loads((Path(directory) / "fault.json").read_text())
        return value.get("mode") if value.get("bridgePID") == os.getpid() else None
    except (OSError, ValueError):
        return None

def forward_input():
    try:
        magic = exactly(sys.stdin.buffer, 8)
        if magic is None:
            return
        process.stdin.write(magic)
        process.stdin.flush()
        while True:
            incoming = frame(sys.stdin.buffer)
            if incoming is None:
                return
            wire, value = incoming
            if value["kind"] == "attach":
                identity.update({"clientID": value["clientId"], "sessionID": value["sessionId"].lower()})
            event("receive", value["kind"], data=value.get("data"))
            process.stdin.write(wire)
            process.stdin.flush()
    finally:
        process.stdin.close()

threading.Thread(target=forward_input, daemon=True).start()
held = []
released = False
try:
    magic = exactly(process.stdout, 8)
    if magic is not None:
        sys.stdout.buffer.write(magic)
        sys.stdout.buffer.flush()
        while True:
            mode = fault()
            if held and mode == "release-old" and not released:
                sys.stdout.buffer.write(held[0])
                sys.stdout.buffer.flush()
                held.clear()
                released = True
                event("released", "pong")
            if held and mode is None:
                for wire in held:
                    sys.stdout.buffer.write(wire)
                sys.stdout.buffer.flush()
                held.clear()
            if not select.select([process.stdout], [], [], 0.05)[0]:
                continue
            outgoing = frame(process.stdout)
            if outgoing is None:
                break
            wire, value = outgoing
            mode = fault()
            if value["kind"] == "pong" and mode == "hold":
                held.append(wire)
                event("held", "pong")
            elif value["kind"] == "pong" and mode in ("drop", "release-old"):
                event("dropped", "pong")
            else:
                sys.stdout.buffer.write(wire)
                sys.stdout.buffer.flush()
                event("send", value["kind"])
finally:
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    os.close(events)
'''


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
    options = parser.parse_args()
    server = options.derived_data.resolve() / "Build/Products/Debug/zshell Debug.app/Contents/Resources/zshell-server"
    if not server.is_file():
        raise SystemExit(f"Build Debug in {options.derived_data} first")
    with tempfile.TemporaryDirectory(prefix="zshell-remote-wake-", dir="/tmp") as temporary:
        directory = Path(temporary)
        ssh = directory / "ssh"
        ssh.mkdir()
        fixture = Fixture(ssh)
        daemon = None
        try:
            fixture.__enter__()
            home = directory / "remote-home"
            home.mkdir()
            (home / ".zshenv").write_text("HISTFILE=/dev/null\n")
            project = home / "project"
            project.mkdir()
            state = directory / "rs"
            adapter = directory / "bridge.py"
            adapter.write_text(BRIDGE)
            wrapper = directory / "zshell-server"
            command = ["/usr/bin/python3", "-u", str(adapter), str(server), str(state), str(directory)]
            wrapper.write_text("#!/bin/sh\nexport HOME=" + shlex.quote(str(home)) + " ZDOTDIR=" + shlex.quote(str(home))
                               + "\nexec " + shlex.join(command) + ' "$@"\n')
            wrapper.chmod(0o755)
            environment = {**os.environ, "HOME": str(home), "ZDOTDIR": str(home)}
            with (directory / "server.log").open("wb") as log:
                daemon = subprocess.Popen([str(server), "serve", "--state", str(state)],
                                          cwd=ROOT, env=environment, stdout=log, stderr=log)
            arguments = [sys.executable, str(ROOT / "mac/tests/test_remote_session_surfaces.py"),
                         "--derived-data", str(options.derived_data.resolve()), "--address", fixture.address,
                         "--directory", str(project), "--ssh-config", str(fixture.config),
                         "--server-path", str(wrapper), "--wake-fixture", str(directory)]
            for backend in options.backend or ():
                arguments += ["--backend", backend]
            subprocess.run(arguments, cwd=ROOT, check=True, timeout=300)
        finally:
            if daemon is not None:
                subprocess.run([str(server), "stop", "--state", str(directory / "rs")],
                               capture_output=True, timeout=10)
                stop(daemon)
            fixture.__exit__()


if __name__ == "__main__":
    main()
