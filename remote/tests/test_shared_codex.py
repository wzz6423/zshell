"""Prove shared Codex hooks bind full IDs to unique foreground TUI titles.

The production daemon and PTYs run against an isolated native-hook fixture. The
shared provider service starts before the panes with no Zshell environment.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import uuid

from test_agents import Bridge, wait


def main(binary):
    passed = 0

    def check(condition, label):
        nonlocal passed
        assert condition, label
        passed += 1
        print("PASS " + label, flush=True)

    with tempfile.TemporaryDirectory(prefix="zs-codex-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home, state, project, providers = [root / name for name in ("home", "state", "project", "providers")]
        for path in (home, project, providers):
            path.mkdir(mode=0o700)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CODEX_HOME": str(home / ".codex"),
                            "AGENT_FIXTURE": str(root), "AGENT_SERVER": binary,
                            "PATH": str(providers) + os.pathsep + environment.get("PATH", "/usr/bin:/bin")})
        environment.pop("CODEX_THREAD_ID", None)
        provider = providers / "codex"
        provider.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, socket, struct, subprocess, sys, time, uuid
from pathlib import Path
root=Path(os.environ["AGENT_FIXTURE"])
state=root/"state"
def receive(stream, count):
    data=b""
    while len(data)<count:
        part=stream.recv(count-len(data))
        if not part:raise EOFError()
        data+=part
    return data
def direct(fields, reporter=None):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.connect(str(state/"control.sock"));stream.sendall(b"ZSRM0001");assert receive(stream,8)==b"ZSRM0001"
        hook={"provider":"codex","token":"","reporterPid":reporter or os.getpid(),"event":fields["hook_event_name"],
              "conversationId":fields["session_id"]}
        if hook["event"]=="SessionStart":
            hook["identity"]={"provider":"codex","sessionID":fields["session_id"],"workingDirectory":fields["cwd"],
                              "configDirectory":os.environ["CODEX_HOME"]}
        request={"version":1,"kind":"agentHook","requestId":str(uuid.uuid4()),"hook":hook}
        data=json.dumps(request).encode();stream.sendall(struct.pack(">I",len(data))+data)
        size=struct.unpack(">I",receive(stream,4))[0];result=json.loads(receive(stream,size))
        return {"status":int("error" in result),"stderr":result.get("error","")}
def hook(fields):
    process=subprocess.run([os.environ["AGENT_SERVER"],"--state",str(state),"hook","codex"],
                           input=json.dumps(fields),text=True,capture_output=True)
    return {"status":process.returncode,"stderr":process.stderr}
if "--nested" in sys.argv:
    print(json.dumps(direct({"hook_event_name":"SessionStart","session_id":sys.argv[-1],"cwd":str(root/"project")})))
    sys.exit(0)
if "--managed-daemon" in sys.argv:
    (root/"shared-ready.json").write_text(json.dumps({"pid":os.getpid(),"zshell":any(key.startswith("ZSHELL_") for key in os.environ)}))
    while True:
        path=root/"shared-command.json"
        if path.exists():
            fields=json.loads(path.read_text());path.unlink()
            if fields.pop("nested",False):
                result=subprocess.run([sys.argv[0],"--nested",fields["session_id"]],text=True,capture_output=True)
                response=json.loads(result.stdout)
            elif "reporter" in fields:response=direct(fields,fields.pop("reporter"))
            else:response=hook(fields)
            (root/"shared-response.json").write_text(json.dumps(response))
        time.sleep(0.01)
else:
    slot=sys.argv[sys.argv.index("--tui")+1]
    identity=sys.argv[-1]
    (root/(slot+"-ready.json")).write_text(json.dumps({"pid":os.getpid()}))
    def title(text):print("\x1b]2;"+text+"\x07",end="",flush=True)
    if identity!="pending":title(identity)
    while True:
        path=root/(slot+"-command.json")
        if path.exists():
            fields=json.loads(path.read_text());path.unlink()
            title(fields["title"])
            (root/(slot+"-response.json")).write_text("{}")
        time.sleep(0.01)
''')
        provider.chmod(0o700)
        bridge = Bridge(binary, state, environment)
        shared = subprocess.Popen([str(provider), "app-server", "--managed-daemon"], env=environment,
                                  cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        remote_ids = []
        try:
            ready = wait(lambda: json.loads((root / "shared-ready.json").read_text()) if (root / "shared-ready.json").exists() else None)
            check(not ready["zshell"], "pre-existing provider daemon has no pane environment or capability")

            def pane(slot, identity):
                terminal = str(uuid.uuid4())
                command = "exec " + shlex.quote(str(provider)) + " --tui " + slot + " " + identity
                result = bridge.call("create", project, sessionId=terminal, command=["/bin/sh", "-ic", command])
                assert "error" not in result, result
                remote_ids.append(terminal)
                wait(lambda: (root / (slot + "-ready.json")).exists())
                return terminal

            def info(terminal):
                return bridge.call("get", project, sessionId=terminal)["result"]

            def snapshot(terminal):
                def receive(stream, count):
                    data = b""
                    while len(data) < count:
                        part = stream.recv(count - len(data))
                        if not part:
                            raise EOFError()
                        data += part
                    return data
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.settimeout(5)
                    stream.connect(str(state / "control.sock"))
                    stream.sendall(b"ZSRM0001")
                    assert receive(stream, 8) == b"ZSRM0001"
                    request = {"version": 1, "kind": "attach", "project": str(project), "sessionId": terminal,
                               "requestId": str(uuid.uuid4()), "clientId": str(uuid.uuid4()), "columns": 80, "rows": 24}
                    data = json.dumps(request).encode()
                    stream.sendall(struct.pack(">I", len(data)) + data)
                    output = b""
                    while True:
                        size = struct.unpack(">I", receive(stream, 4))[0]
                        frame = json.loads(receive(stream, size))
                        assert "error" not in frame, frame
                        if frame["kind"] == "snapshot":
                            output += base64.b64decode(frame["data"])
                        if frame["kind"] == "snapshotEnd":
                            return output

            def conversation(terminal):
                value = info(terminal)["conversation"]
                return value["sessionID"] if value else None

            def report(identity, event="SessionStart", **fields):
                response = root / "shared-response.json"
                response.unlink(missing_ok=True)
                (root / "shared-command.json").write_text(json.dumps({"hook_event_name": event, "session_id": identity, "cwd": str(project), **fields}))
                return wait(lambda: json.loads(response.read_text()) if response.exists() else None)

            def title(slot, value):
                response = root / (slot + "-response.json")
                response.unlink(missing_ok=True)
                (root / (slot + "-command.json")).write_text(json.dumps({"title": value}))
                wait(lambda: response.exists())

            first, second, third = [str(uuid.uuid4()) for _ in range(3)]
            pane_a = pane("a", first)
            pane_b = pane("b", second)
            wait(lambda: info(pane_a)["totalOutputBytes"] > 0)
            check(b"\x1b]2;" + first.encode() + b"\x1b\\" in snapshot(pane_a),
                  "late attachments replay the safe provider title from before the client connected")
            check(conversation(pane_a) is None and conversation(pane_b) is None, "titles alone cannot create history or guess identity by cwd")
            check(report(first)["status"] == 0, "kernel-verified shared SessionStart is accepted without a pane token")
            wait(lambda: conversation(pane_a) == first)
            check(conversation(pane_b) is None, "first full ID binds only its foreground TUI")
            check(report(second)["status"] == 0, "second native conversation in the same cwd is accepted")
            wait(lambda: conversation(pane_b) == second)
            check(conversation(pane_a) == first, "same-cwd dual panes retain distinct full provider IDs")
            report(first, "UserPromptSubmit")
            wait(lambda: info(pane_a)["agentStatus"]["phase"] == "working")
            check(info(pane_b)["agentStatus"]["phase"] == "idle", "shared lifecycle reaches only the exact bound conversation")
            check(report(third)["status"] == 0, "SessionStart can arrive before a matching TUI title")
            report(third, "UserPromptSubmit")
            pane_c = pane("c", "pending")
            check(conversation(pane_c) is None, "pending native identity remains unbound until provider title evidence")
            title("c", third[:29] + "...")
            wait(lambda: conversation(pane_c) == third)
            check(info(pane_c)["agentStatus"]["phase"] == "working", "hook-before-title preserves lifecycle and binds the verified full UUID")
            title("b", first)
            wait(lambda: conversation(pane_a) is None and conversation(pane_b) is None)
            check(True, "a duplicate thread title revokes both ambiguous pane bindings")
            title("b", second)
            wait(lambda: conversation(pane_a) == first and conversation(pane_b) == second)
            check(True, "unique titles can recover after a duplicate is resolved")
            collision = third[:29] + ("1111111" if third[29:] != "1111111" else "2222222")
            report(collision)
            wait(lambda: conversation(pane_c) is None)
            check(True, "colliding official title prefixes revoke the existing binding")
            title("c", third)
            wait(lambda: conversation(pane_c) == third)
            check(True, "a full provider UUID disambiguates the prefix collision")
            history = bridge.call("agentHistory", project)["result"]
            check(all(len(item["identity"]["sessionID"]) == 36 for item in history)
                  and not any(item["identity"]["sessionID"] == collision for item in history), "history contains only full IDs that were uniquely bound")
            check(report(str(uuid.uuid4()), nested=True)["status"] != 0, "nested CLI beneath the shared service cannot impersonate a root conversation")
            check(report(first, reporter=ready["pid"] + 1)["status"] != 0, "kernel peer rejects an unrelated reporter PID")
            bridge.call("terminate", project, sessionId=pane_a)
            report(second, "PermissionRequest")
            wait(lambda: info(pane_b)["agentStatus"]["attention"] == "approval")
            check(True, "shared hooks keep working after the first pane closes")
            report(second, "Stop")
            wait(lambda: info(pane_b)["agentStatus"]["phase"] == "done")
            check(True, "shared completion remains visible until acknowledged")
            title("b", "unrelated title")
            wait(lambda: conversation(pane_b) is None)
            check(True, "unrelated provider title revokes its old conversation identity")
        finally:
            shared.terminate()
            try:
                shared.wait(timeout=3)
            except subprocess.TimeoutExpired:
                shared.kill()
                shared.wait(timeout=3)
            try:
                bridge.call("shutdown", project)
            except (OSError, EOFError, ValueError, BrokenPipeError):
                pass
            bridge.close()
    print(f"{passed} shared Codex production checks passed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    options = parser.parse_args()
    main(str(options.binary.resolve()))
