"""Exercise the production daemon, stdio bridge and CLI against real PTYs.

Run after cargo build --locked:
    python3 remote/tests/test_cli.py --binary remote/target/debug/zshell-server
Run as root in an isolated Linux environment to also prove the different-UID
socket rejection with --require-other-uid. All state and jobs belong to this test.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid


MAGIC = b"ZSRM0001"
passed = 0


def check(condition, name):
    global passed
    if not condition:
        raise AssertionError(name)
    passed += 1
    print(f"PASS {name}", flush=True)


def wait_until(predicate, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.03)
    return False


def read_exact(descriptor, count, timeout=6):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while len(output) < count:
        ready, _, _ = select.select([descriptor], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            raise TimeoutError("Remote protocol read timed out")
        chunk = os.read(descriptor, count - len(output))
        if not chunk:
            raise EOFError("Remote protocol ended early")
        output.extend(chunk)
    return bytes(output)


class Client:
    def __init__(self, fixture, session, columns=80, rows=24):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.process = subprocess.Popen(
            fixture.arguments("attach", session), stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True,
        )
        os.close(slave)
        fixture.clients.append(self)
        self.output = bytearray()

    def through(self, marker, timeout=6):
        deadline = time.monotonic() + timeout
        while marker not in self.output:
            ready, _, _ = select.select([self.master], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise AssertionError(f"Missing terminal marker {marker!r}; tail={self.output[-300:]!r}")
            try:
                chunk = os.read(self.master, 65536)
            except OSError as error:
                raise AssertionError(f"CLI ended before {marker!r}; tail={self.output[-300:]!r}") from error
            if not chunk:
                raise EOFError("CLI PTY closed")
            self.output.extend(chunk)
        return bytes(self.output)

    def send(self, text):
        os.write(self.master, text.encode())

    def detach(self):
        os.write(self.master, b"\x1d")
        return self.process.wait(timeout=6)

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        os.close(self.master)


class Fixture:
    def __init__(self, binary, root):
        self.binary = str(binary)
        self.root = root
        self.state = root / "state"
        self.project = root / "远端 project 'quoted'"
        self.other = root / "other"
        self.project.mkdir()
        self.other.mkdir()
        self.clients = []

    def arguments(self, command, session=None, project=None):
        arguments = [self.binary, command, "--state", str(self.state), "--project", str(project or self.project)]
        if session:
            arguments += ["--session", session]
        return arguments

    def call(self, command, session=None, program=None, project=None):
        arguments = self.arguments(command, session, project)
        if program:
            arguments += ["--", *program]
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise AssertionError(f"{command}: {result.stderr}")
        return json.loads(result.stdout)

    def create(self, program):
        session = str(uuid.uuid4())
        return session, self.call("create", session, program)

    def info(self, session):
        return next(info for info in self.call("list") if info["sessionId"] == session)

    def close(self):
        try:
            self.call("stop")
        except (AssertionError, subprocess.TimeoutExpired):
            pass
        for client in self.clients:
            client.close()


def bridge_probe(fixture, session):
    bridge = subprocess.Popen(
        fixture.arguments("bridge"), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        bridge.stdin.write(MAGIC)
        bridge.stdin.flush()
        check(read_exact(bridge.stdout.fileno(), 8) == MAGIC, "production stdio bridge handshake")

        def exchange(kind, project):
            request_id = str(uuid.uuid4())
            request = json.dumps({"version": 1, "kind": kind, "requestId": request_id,
                                  "project": str(project), "sessionId": session}).encode()
            bridge.stdin.write(struct.pack(">I", len(request)) + request)
            bridge.stdin.flush()
            size = struct.unpack(">I", read_exact(bridge.stdout.fileno(), 4))[0]
            response = json.loads(read_exact(bridge.stdout.fileno(), size))
            check(response["requestId"] == request_id, f"bridge {kind} correlates response")
            return response

        result = exchange("get", fixture.project)
        check(result["result"]["sessionId"] == session, "stdio bridge reaches the existing PTY")
        result = exchange("terminate", fixture.other)
        check("different project" in result["error"], "bridge rejects a cross-project terminate")
    finally:
        bridge.stdin.close()
        try:
            bridge.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait(timeout=3)


def different_uid_probe(fixture, require):
    if sys.platform != "linux" or os.geteuid() != 0:
        if require:
            raise AssertionError("The different-UID probe requires an isolated Linux root environment")
        print("NOT RUN different-UID socket probe: requires isolated Linux root", flush=True)
        return
    control = fixture.state / "control.sock"
    modes = [path.stat().st_mode & 0o777 for path in (fixture.root, fixture.state, control)]
    try:
        fixture.root.chmod(0o755)
        fixture.state.chmod(0o755)
        control.chmod(0o666)
        code = """
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(2)
s.connect(sys.argv[1])
print('connected', flush=True)
try:
    s.sendall(b'ZSRM0001')
    reply = s.recv(8)
except (BrokenPipeError, ConnectionResetError):
    reply = b''
sys.exit(0 if not reply else 1)
"""

        def lower_uid():
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)

        outsider = subprocess.run([sys.executable, "-c", code, str(control)],
                                  preexec_fn=lower_uid, capture_output=True, text=True, timeout=4)
        check(outsider.returncode == 0 and "connected" in outsider.stdout,
              "daemon rejects an actual different UID even when socket permissions permit connecting")
    finally:
        for path, mode in zip((fixture.root, fixture.state, control), modes):
            path.chmod(mode)
    check(fixture.call("status")["protocolVersion"] == 1, "owner remains connected after the UID probe")


def process_alive(pid):
    try:
        if sys.platform == "linux" and Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].startswith("Z "):
            return False
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, FileNotFoundError):
        return False


def run(fixture, require_uid):
    session, original = fixture.create(["/bin/sh", "-i"])
    check(original["running"] and original["pid"] > 1, "CLI creates a real persistent shell")
    check(fixture.state.stat().st_mode & 0o777 == 0o700, "daemon state has 0700 permissions")
    check((fixture.state / "control.sock").stat().st_mode & 0o777 == 0o600, "control socket has 0600 permissions")
    first = Client(fixture, session)
    check(wait_until(lambda: fixture.info(session)["clientCount"] == 1), "CLI attaches to the session")
    first.send("printf '\\nCLI_BEFORE\\n'; sleep 0.3; printf 'CLI_OFFLINE\\n'\r")
    first.through(b"\r\nCLI_BEFORE\r\n")
    check(first.detach() == 0, "Ctrl-] detaches without an error")
    time.sleep(0.4)
    check(fixture.info(session)["pid"] == original["pid"] and fixture.info(session)["running"],
          "disconnect preserves the original shell PID")
    second = Client(fixture, session, 100, 30)
    second.through(b"CLI_OFFLINE")
    check(b"CLI_BEFORE" in second.output, "reattaching restores output written before and during disconnect")
    third = Client(fixture, session, 120, 35)
    check(wait_until(lambda: fixture.info(session)["clientCount"] == 2 and fixture.info(session)["columns"] == 120),
          "two CLI clients share one PTY and the latest claim controls its size")
    third.send("printf '\\nMULTI_CLI\\n'; stty size\r")
    second.through(b"\r\nMULTI_CLI\r\n")
    third.through(b"35 120\r\n")
    check(True, "both clients receive the same command output")
    third.resize(110, 32)
    check(wait_until(lambda: fixture.info(session)["columns"] == 110 and fixture.info(session)["rows"] == 32),
          "SIGWINCH applies the controlling client's new dimensions")
    check(third.detach() == 0, "second client detaches cleanly")
    check(wait_until(lambda: fixture.info(session)["clientCount"] == 1 and fixture.info(session)["columns"] == 100),
          "remaining client regains control and its own dimensions")
    bridge_probe(fixture, session)
    different_uid_probe(fixture, require_uid)
    second.detach()
    fixture.call("terminate", session)
    check(wait_until(lambda: not process_alive(original["pid"])), "explicit terminate ends the remote shell")
    exited, _ = fixture.create(["/bin/sh", "-c", "printf 'EXIT_LAST_LINE\\n'; exit 7"])
    finished = Client(fixture, exited)
    finished.through(b"EXIT_LAST_LINE")
    check(finished.process.wait(timeout=6) == 7, "CLI preserves the remote exit status and final output")
    signaled, _ = fixture.create(["/bin/sh", "-c", "kill -TERM $$"])
    signal_client = Client(fixture, signaled)
    check(signal_client.process.wait(timeout=6) == 143, "remote signal exit is reported as 128 plus signal")
    child_file = fixture.project / "background-pid"
    background, _ = fixture.create(["/bin/sh", "-c", f"sleep 30 & echo $! > {shlex.quote(str(child_file))}; wait"])
    check(wait_until(child_file.exists), "remote background job starts")
    child_pid = int(child_file.read_text())
    fixture.call("terminate", background)
    check(wait_until(lambda: not process_alive(child_pid)), "terminate ends the remote background job too")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--require-other-uid", action="store_true")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zshell-remote-cli-", dir="/tmp") as temporary:
        fixture = Fixture(options.binary.resolve(), Path(temporary))
        try:
            run(fixture, options.require_other_uid)
        finally:
            fixture.close()
    print(f"Remote CLI: {passed} passed, 0 failed", flush=True)
