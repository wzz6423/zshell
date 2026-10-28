"""Exercise Windows production CLI, ConPTY sessions, and binary stdio bridging."""

import argparse
import base64
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import tempfile
import threading
import time
import uuid


passed = 0
MAGIC = b"ZSRM0001"


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print(f"PASS {label}", flush=True)


def wait_for(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.04)
    return condition()


class Bridge:
    def __init__(self, fixture):
        self.process = subprocess.Popen(fixture.arguments("bridge"), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.closed = False
        fixture.bridges.append(self)
        self.chunks = queue.Queue()
        self.buffer = bytearray()

        def collect():
            try:
                while chunk := self.process.stdout.read1(65536):
                    self.chunks.put(chunk)
            finally:
                self.chunks.put(None)

        self.reader = threading.Thread(target=collect, daemon=True)
        self.reader.start()
        self.process.stdin.write(MAGIC)
        self.process.stdin.flush()
        check(self.read(8) == MAGIC, "Windows binary stdio handshake")

    def read(self, count, timeout=10):
        deadline = time.monotonic() + timeout
        while len(self.buffer) < count:
            chunk = self.chunks.get(timeout=max(0.01, deadline - time.monotonic()))
            if chunk is None:
                raise EOFError(f"Bridge closed: {self.process.stderr.read()!r}")
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def send(self, request):
        data = json.dumps({"version": 1, **request}, ensure_ascii=False).encode()
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()

    def frame(self):
        size = struct.unpack(">I", self.read(4))[0]
        check(0 < size <= 256 * 1024, "Windows bridge frame bound")
        return json.loads(self.read(size))

    def exchange(self, kind, **fields):
        request = {"kind": kind, "requestId": str(uuid.uuid4()), **fields}
        self.send(request)
        response = self.frame()
        check(response.get("requestId") == request["requestId"], f"Windows {kind} response correlation")
        return response

    def through(self, predicate):
        output = bytearray()
        while True:
            frame = self.frame()
            check(not frame.get("error"), "Windows attached frame succeeds")
            if frame["kind"] in ("snapshot", "output"):
                output.extend(base64.b64decode(frame["data"]))
            if predicate(frame, output):
                return output

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdin.close()
        self.reader.join(timeout=3)
        self.process.stdout.close()
        self.process.stderr.close()


class Fixture:
    def __init__(self, binary, root):
        self.binary = str(binary)
        self.state = root / "state"
        self.project = root / "远端 project 'quoted'"
        self.other = root / "other"
        self.project.mkdir()
        self.other.mkdir()
        self.bridges = []

    def arguments(self, kind, session=None, project=None):
        arguments = [self.binary, kind, "--state", str(self.state), "--project", str(project or self.project)]
        if session:
            arguments += ["--session", session]
        return arguments

    def call(self, kind, session=None, program=None, project=None):
        arguments = self.arguments(kind, session, project)
        if program:
            arguments += ["--", *program]
        result = subprocess.run(arguments, capture_output=True, timeout=15)
        if result.returncode:
            raise AssertionError(f"{kind}: {result.stderr!r}")
        return json.loads(result.stdout)

    def info(self, session):
        return next(info for info in self.call("list") if info["sessionId"] == session)

    def attach(self, session):
        bridge = Bridge(self)
        client = str(uuid.uuid4())
        bridge.send({"kind": "attach", "project": str(self.project), "sessionId": session,
                     "clientId": client, "columns": 160, "rows": 30})
        check(bridge.frame()["kind"] == "attached", "Windows real ConPTY attaches")
        snapshot = bridge.through(lambda frame, _: frame["kind"] == "snapshotEnd")
        return bridge, client, snapshot

    def close(self):
        for bridge in self.bridges:
            bridge.close()
        try:
            self.call("stop")
        except (AssertionError, subprocess.TimeoutExpired):
            pass


def run(fixture):
    version = subprocess.run([fixture.binary, "--version", "--json"], capture_output=True, check=True, timeout=5)
    metadata = json.loads(version.stdout)
    check(metadata["platform"] == "windows" and metadata["protocolVersion"] == 1,
          "Windows server reports its actual installation metadata")
    absent = subprocess.run(fixture.arguments("status"), capture_output=True, timeout=5)
    check(absent.returncode != 0, "status does not start a Windows daemon")
    subprocess.run(fixture.arguments("start"), capture_output=True, check=True, timeout=12)
    check(fixture.call("status")["platform"] == "windows", "Windows private daemon starts")
    session = str(uuid.uuid4())
    original = fixture.call("create", session)
    check(original["running"] and original["pid"] > 0, "default Windows shell runs in ConPTY")
    bridge, client, _ = fixture.attach(session)
    bridge.send({"kind": "input", "data": base64.b64encode(b"echo WINDOWS_PERSIST > persistent.txt\r").decode()})
    check(wait_for(lambda: (fixture.project / "persistent.txt").exists()), "Windows CLI input reaches the actual host filesystem")
    bridge.close()
    check(wait_for(lambda: fixture.info(session)["clientCount"] == 0), "Windows bridge disconnect detaches its client")
    second, active, replay = fixture.attach(session)
    check(fixture.info(session)["pid"] == original["pid"] and b"WINDOWS_PERSIST" in replay,
          "Windows reconnect preserves PID and terminal history")
    passive, passive_id, _ = fixture.attach(session)
    passive.send({"kind": "input", "data": base64.b64encode(b"echo BAD > passive.txt\r").decode()})
    passive.send({"kind": "ping"})
    passive.through(lambda frame, _: frame["kind"] == "pong")
    check(not (fixture.project / "passive.txt").exists(), "Windows passive client cannot type")
    passive.send({"kind": "claim"})
    passive.through(lambda frame, _: frame["kind"] == "state" and frame.get("result", {}).get("activeClientId") == passive_id)
    passive.send({"kind": "resize", "columns": 120, "rows": 35})
    passive.through(lambda frame, _: frame["kind"] == "state" and frame.get("result", {}).get("columns") == 120)
    check(fixture.info(session)["rows"] == 35, "Windows controller resize reaches ConPTY")

    upload = Bridge(fixture)
    identity = {"project": str(fixture.project), "sessionId": session, "clientId": passive_id}
    started = upload.exchange("pasteStart", pasteFiles=[{"name": "image 'quoted'.png", "size": 3}], **identity)
    check(not started.get("error"), "Windows private paste upload starts")
    upload_id = started["result"]["uploadId"]
    check(not upload.exchange("pasteChunk", uploadId=upload_id, fileIndex=0, offset=0,
                              data=base64.b64encode(bytes([0, 1, 255])).decode(), **identity).get("error"),
          "Windows paste binary chunk succeeds")
    committed = upload.exchange("pasteCommit", uploadId=upload_id, **identity)
    pasted_path = committed["result"]["paths"][0]
    check(not pasted_path.startswith("\\\\?\\"), "Windows paste returns a native shell path")
    check(Path(pasted_path).read_bytes() == bytes([0, 1, 255]),
          "Windows paste atomically commits binary content")
    paste_command = f'copy /b "{pasted_path}" "pasted-by-shell.bin" >nul\r'
    passive.send({"kind": "input", "data": base64.b64encode(paste_command.encode("utf-8")).decode()})
    copied_path = fixture.project / "pasted-by-shell.bin"
    check(wait_for(copied_path.is_file) and copied_path.read_bytes() == bytes([0, 1, 255]),
          "default Windows shell reads a quoted pasted path as one argument")
    powershell = str(Path(os.environ.get("SystemRoot", r"C:\Windows")) /
                     "System32/WindowsPowerShell/v1.0/powershell.exe")
    ps_session = str(uuid.uuid4())
    ps_info = fixture.call("create", ps_session, [powershell, "-NoLogo", "-NoProfile", "-NoExit"])
    check(Path(ps_info["command"][0]).name.lower() == "powershell.exe", "PowerShell session preserves its actual command")
    ps_bridge, _, _ = fixture.attach(ps_session)
    ps_literal = "'" + "".join(char * 2 if char in "'‘’‚‛" else char for char in pasted_path) + "'"
    ps_target = "'" + str(fixture.project / "pasted-by-powershell.bin").replace("'", "''") + "'"
    ps_command = f'[IO.File]::WriteAllBytes({ps_target}, [IO.File]::ReadAllBytes({ps_literal}))\r'
    ps_bridge.send({"kind": "input", "data": base64.b64encode(ps_command.encode("utf-8")).decode()})
    ps_copy = fixture.project / "pasted-by-powershell.bin"
    check(wait_for(ps_copy.is_file) and ps_copy.read_bytes() == bytes([0, 1, 255]),
          "PowerShell reads the quoted pasted path as one literal argument")
    curly_path = fixture.project / "it‘s’s‚s‛s.png"
    curly_path.write_bytes(bytes([0, 1, 255]))
    curly_literal = "'" + "".join(char * 2 if char in "'‘’‚‛" else char for char in str(curly_path)) + "'"
    curly_target = "'" + str(fixture.project / "curly-powershell.bin").replace("'", "''") + "'"
    ps_command = f'[IO.File]::WriteAllBytes({curly_target}, [IO.File]::ReadAllBytes({curly_literal}))\r'
    ps_bridge.send({"kind": "input", "data": base64.b64encode(ps_command.encode("utf-8")).decode()})
    curly_copy = fixture.project / "curly-powershell.bin"
    check(wait_for(curly_copy.is_file) and curly_copy.read_bytes() == bytes([0, 1, 255]),
          "PowerShell keeps all curly single-quote delimiters literal")
    ps_bridge.close()
    fixture.call("terminate", ps_session)
    wrong = upload.exchange("get", project=str(fixture.other), sessionId=session)
    check("different project" in wrong.get("error", ""), "Windows project boundary rejects another directory")

    cmd = os.environ.get("COMSPEC", r"C:\Windows\System32\cmd.exe")
    finished = str(uuid.uuid4())
    fixture.call("create", finished, [cmd, "/D", "/C", "echo WINDOWS_FINAL & exit /b 7"])
    check(wait_for(lambda: not fixture.info(finished)["running"]), "Windows root process exits")
    check(fixture.info(finished)["exitCode"] == 7, "Windows exit status is preserved")
    final_client, _, final_output = fixture.attach(finished)
    check(b"WINDOWS_FINAL" in final_output, "Windows final output drains before exit publication")
    final_client.close()

    attached = subprocess.Popen(fixture.arguments("attach", session), stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.6)
        attached.stdin.write(b"\x1d")
        attached.stdin.flush()
        check(attached.wait(timeout=10) == 0, "Windows CLI Ctrl-] explicitly detaches")
    finally:
        if attached.poll() is None:
            attached.kill()
            attached.wait(timeout=5)
        for handle in (attached.stdin, attached.stdout, attached.stderr):
            handle.close()
    fixture.call("terminate", session)
    check(not any(info["sessionId"] == session for info in fixture.call("list")), "Windows terminate removes the shared session")
    bad = subprocess.run(fixture.arguments("serve") + ["--listen", "0.0.0.0:7373"], capture_output=True, timeout=5)
    check(bad.returncode != 0, "Windows rejects unauthenticated public listening")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
options = parser.parse_args()
if os.name != "nt":
    raise SystemExit("This probe must run on a real Windows host")
with tempfile.TemporaryDirectory(prefix="zshell-cli-windows-") as temporary:
    fixture = Fixture(options.binary.resolve(), Path(temporary))
    try:
        run(fixture)
    finally:
        fixture.close()
print(f"{passed} Windows production checks passed", flush=True)
