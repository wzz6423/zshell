"""Exercise remote Agent hooks, state, project ownership and durable exact resume.

Uses the production binary and real PTYs. Provider fixtures and private HOME,
configuration, daemon state and processes are removed after the run.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile
import time
import uuid

MAGIC = b"ZSRM0001"


def wait(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.03)
    raise AssertionError("Agent fixture timed out")


class Bridge:
    def __init__(self, binary, state, environment):
        self.process = subprocess.Popen([binary, "bridge", "--state", str(state)], env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.process.stdin.write(MAGIC)
        self.process.stdin.flush()
        reply = self.process.stdout.read(8)
        if reply != MAGIC:
            log = (Path(state) / "daemon.log").read_text() if (Path(state) / "daemon.log").exists() else ""
            raise AssertionError(self.process.stderr.read().decode() + log)

    def call(self, kind, project, **values):
        request = {"version": 1, "kind": kind, "project": str(project), "requestId": str(uuid.uuid4()), **values}
        data = json.dumps(request).encode()
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()
        size = struct.unpack(">I", self.process.stdout.read(4))[0]
        response = json.loads(self.process.stdout.read(size))
        assert response["requestId"] == request["requestId"]
        return response

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)


def main(binary):
    passed = 0

    def check(condition, label):
        nonlocal passed
        assert condition, label
        passed += 1
        print("PASS " + label, flush=True)

    with tempfile.TemporaryDirectory(prefix="zs-agent-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home, state, project, other, providers = [root / name for name in ("home", "state", "project", "other", "providers")]
        for path in (home, project, other, providers):
            path.mkdir(mode=0o700)
        session_id = str(uuid.uuid4())
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "PATH": str(providers) + os.pathsep + environment.get("PATH", "/usr/bin:/bin"),
                            "AGENT_FIXTURE": str(root), "AGENT_ID": session_id, "CLAUDE_CONFIG_DIR": str(home / ".claude")})
        environment.pop("CODEX_THREAD_ID", None)
        for key in ("CODEX_HOME", "PI_CODING_AGENT_DIR", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
            environment.pop(key, None)
        fixture = providers / "claude"
        fixture.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, subprocess, sys, time
from pathlib import Path
root=Path(os.environ["AGENT_FIXTURE"])
session=sys.argv[sys.argv.index("--resume")+1] if "--resume" in sys.argv else os.environ["AGENT_ID"]
server=os.environ["ZSHELL_EXECUTABLE"]
payload={"hook_event_name":"SessionStart","session_id":session,"cwd":os.getcwd()}
def hook(fields, environment=None):
    result=subprocess.run([server,"hook","claude"], input=json.dumps(fields),text=True,capture_output=True,env=environment)
    return {"status":result.returncode,"stderr":result.stderr}
result=hook(payload)
(root/"started.json").write_text(json.dumps({"session":session,"argv":sys.argv[1:],"cwd":os.getcwd(),"status":result["status"],"stderr":result["stderr"]}))
print("AGENT_READY",flush=True)
while True:
    command=root/"command.json"
    if command.exists():
        fields=json.loads(command.read_text());command.unlink()
        if fields.get("nested"):
            child=root/"providers"/"codex"
            result=subprocess.run([str(child)],text=True,capture_output=True)
            response={"status":result.returncode,"stderr":result.stderr}
        else:
            env=dict(os.environ)
            env.update(fields.pop("environment",{}))
            response=hook(fields,env)
        (root/"response.json").write_text(json.dumps(response))
    if (root/"stop").exists():break
    time.sleep(0.01)
''')
        fixture.chmod(0o700)
        nested = providers / "codex"
        nested.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, subprocess, sys
if "app-server" in sys.argv:
    from pathlib import Path
    import tomllib
    root=Path(os.environ["CODEX_HOME"])
    for line in sys.stdin:
        request=json.loads(line)
        method=request["method"]
        if method=="initialize":result={}
        elif method=="initialized":continue
        elif method=="config/read":
            path=root/"config.toml"
            result={"config":tomllib.loads(path.read_text()) if path.exists() else {}}
        elif method=="config/value/write":
            path=Path(request["params"]["filePath"])
            original=path.read_text() if path.exists() else ""
            path.write_text(original+"\n[tui]\nterminal_title = "+json.dumps(request["params"]["value"])+"\n")
            result={}
        else:raise AssertionError(method)
        print(json.dumps({"id":request["id"],"result":result}),flush=True)
    sys.exit(0)
payload={"hook_event_name":"SessionStart","session_id":os.environ["AGENT_ID"],"cwd":os.getcwd()}
result=subprocess.run([os.environ["ZSHELL_EXECUTABLE"],"hook","claude"], input=json.dumps(payload),text=True)
sys.exit(result.returncode)
''')
        nested.chmod(0o700)
        installed = subprocess.run([binary, "agent-hooks", "install"], env=environment, capture_output=True, text=True, check=True)
        check({item["provider"] for item in json.loads(installed.stdout)["providers"]} == {"claude", "codex", "pi", "opencode"}, "install reuses all four provider integrations")
        before = (home / ".claude/settings.json").read_bytes()
        subprocess.run([binary, "agent-hooks", "install"], env=environment, capture_output=True, text=True, check=True)
        check(before == (home / ".claude/settings.json").read_bytes(), "hook installation is idempotent")
        title = (home / ".codex/config.toml").read_text()
        check('"session-id"' in title, "Codex's configuration API enables the provider session title")
        bridge = Bridge(binary, state, environment)
        try:
            terminal_id = str(uuid.uuid4())
            response = bridge.call("create", project, sessionId=terminal_id,
                                   command=["/bin/sh", "-ic", shlex.quote(str(fixture))])
            check("error" not in response, "Agent starts in a daemon-owned PTY")
            started = wait(lambda: json.loads((root / "started.json").read_text()) if (root / "started.json").exists() else None)
            check(started["status"] == 0, "kernel peer and foreground root hook are accepted: " + started.get("stderr", "") + ((state / "daemon.log").read_text() if started["status"] != 0 else ""))
            info = bridge.call("get", project, sessionId=terminal_id)["result"]
            check(info["conversation"]["sessionID"] == session_id, "remote SessionStart retains exact provider identity")

            def report(fields):
                response_path = root / "response.json"
                response_path.unlink(missing_ok=True)
                (root / "command.json").write_text(json.dumps(fields))
                return wait(lambda: json.loads(response_path.read_text()) if response_path.exists() else None)

            check(report({"hook_event_name": "UserPromptSubmit"})["status"] == 0, "native work lifecycle is accepted")
            check(bridge.call("get", project, sessionId=terminal_id)["result"]["agentStatus"]["phase"] == "working", "work status reaches the remote state stream")
            check(report({"hook_event_name": "PermissionRequest"})["status"] == 0, "native approval lifecycle is accepted")
            status = bridge.call("get", project, sessionId=terminal_id)["result"]["agentStatus"]
            check(status["phase"] == "blocked" and status["attention"] == "approval", "remote approval uses the existing attention vocabulary")
            check(report({"hook_event_name": "Stop"})["status"] == 0, "native completion lifecycle is accepted")
            check(bridge.call("get", project, sessionId=terminal_id)["result"]["agentStatus"]["phase"] == "done", "completion is retained until acknowledged")
            stale_id = str(uuid.uuid4())
            stale_status = report({"hook_event_name": "PermissionRequest", "session_id": stale_id})["status"]
            current = bridge.call("get", project, sessionId=terminal_id)["result"]
            check(stale_status != 0 and current["conversation"]["sessionID"] == session_id
                  and current["agentStatus"]["phase"] == "done",
                  "a stale conversation lifecycle cannot change the current Agent state")
            stale_status = report({"hook_event_name": "SessionEnd", "session_id": stale_id})["status"]
            current = bridge.call("get", project, sessionId=terminal_id)["result"]
            check(stale_status != 0 and current["conversation"]["sessionID"] == session_id,
                  "an old SessionEnd never clears the currently bound conversation")
            check(report({"hook_event_name": "UserPromptSubmit", "session_id": session_id})["status"] == 0,
                  "the exact current conversation lifecycle remains accepted")
            check(report({"hook_event_name": "Stop"})["status"] == 0,
                  "legacy lifecycle events without a conversation ID remain accepted")
            for invalid_id in ("", "invalid", None, 1):
                check(report({"hook_event_name": "Stop", "session_id": invalid_id})["status"] != 0,
                      "an invalid explicit conversation ID never falls back to legacy lifecycle handling")
            child = {"hook_event_name": "SubagentStop", "agent_id": "child", "session_id": stale_id,
                     "parent_session_id": session_id}
            check(report(child)["status"] == 0, "a child lifecycle uses its explicit parent conversation ID")
            child["parent_session_id"] = stale_id
            check(report(child)["status"] != 0, "a child lifecycle never updates a different parent conversation")
            check(report({"hook_event_name": "SubagentStop", "agent_id": "child", "session_id": stale_id})["status"] == 0,
                  "legacy child events without a parent ID retain task-based handling")
            check(report({"nested": True})["status"] != 0, "nested provider cannot impersonate the foreground root")
            forged = {"hook_event_name": "SessionStart", "session_id": session_id, "cwd": str(other)}
            check(report(forged)["status"] != 0, "hook rejects a conversation in another project")
            forged["cwd"] = str(project)
            forged["environment"] = {"ZSHELL_TERMINAL_ID": str(uuid.uuid4())}
            check(report(forged)["status"] != 0, "hook rejects a terminal selected by forged environment")
            history = bridge.call("agentHistory", project)["result"]
            check(len(history) == 1 and history[0]["identity"]["sessionID"] == session_id, "durable history stores only the verified root conversation")
            mode = (state / "conversations.json").stat().st_mode & 0o777
            check(mode == 0o600, "remote history is an owner-only file")
            reused = bridge.call("agentResume", project, provider="claude", conversationId=session_id)["result"]
            check(reused["sessionId"] == terminal_id, "resume keeps an existing live Agent PTY")
            fixture.rename(providers / "claude.off")
            try:
                reused = bridge.call("agentResume", project, provider="claude", conversationId=session_id)
            finally:
                (providers / "claude.off").rename(fixture)
            check(reused.get("result", {}).get("sessionId") == terminal_id, "resume keeps a live Agent PTY after the provider leaves PATH")
            check("error" in bridge.call("agentResume", other, provider="claude", conversationId=session_id), "resume cannot cross remote project boundaries")

            def scripted(script):
                scripted_id = str(uuid.uuid4())
                bridge.call("create", project, sessionId=scripted_id, command=["/bin/sh", "-c",
                            script + r"; printf '\033]7501;state=idle:id=sentinel\007'; exec sleep 30"])
                status = wait(lambda: next((status for status in [bridge.call("get", project, sessionId=scripted_id)["result"]["agentStatus"]]
                                            if any(record["id"] == "sentinel" for record in status["records"])), None))
                bridge.call("terminate", project, sessionId=scripted_id)
                return status, {record["id"]: record for record in status["records"]}

            status, records = scripted(r"printf '\033]7501;state=work'; sleep 0.2; printf 'ing:id=split\007'")
            check(records.get("split", {}).get("state") == "working", "OSC 7501 split across PTY reads is reassembled")
            status, records = scripted(r"printf '\033]7501;state=blocked:id=cut\033]7501;state=working:id=next\007'")
            check("cut" not in records and records.get("next", {}).get("state") == "working", "truncated OSC 7501 is dropped and the next sequence still applies")
            status, records = scripted(r"printf '\033]7501;state=working:id=old\007\033]7501;state=blocked:id=cut\033c'")
            check(set(records) == {"sentinel"}, "terminal reset after a truncated OSC 7501 clears earlier records")
            status, records = scripted(r"printf '\033]133;A\007\033]7501;state=working:id=late\007'")
            check(status["phase"] == "working" and "late" in records, "an earlier OSC 133 prompt does not drop later work")
            status, records = scripted(r"printf '\033]7501;state=working:id=live\007\033]7501;state=done:id=finished\007\033]133;A\007'")
            check("live" not in records and records.get("finished", {}).get("state") == "done", "OSC 133 prompt drops live work but keeps completion")
            status, records = scripted(r"printf '\033]7501;state=clear:id=ghost\007\033]7501;state=working:id=p/c\007\033]7501;state=done:id=p:app=codex\007'")
            check(status["phase"] == "working" and records.get("p/c", {}).get("app") == "codex", "out-of-order child and parent records resolve the parent app")
            bridge.call("shutdown", project)
            bridge.close()
            time.sleep(0.8)
            (root / "started.json").unlink()
            bridge = Bridge(binary, state, environment)
            history = bridge.call("agentHistory", project)["result"]
            check(len(history) == 1 and history[0]["identity"]["sessionID"] == session_id, "history survives a production daemon restart")
            check(str(project) in bridge.call("projects", project)["result"], "history-only remote projects remain discoverable")
            resumed = bridge.call("agentResume", project, provider="claude", conversationId=session_id)["result"]
            started = wait(lambda: json.loads((root / "started.json").read_text()) if (root / "started.json").exists() else None)
            check(resumed["sessionId"] != terminal_id and started["argv"] == ["--resume", session_id]
                  and started["session"] == session_id and started["cwd"] == str(project), "restarted daemon invokes the exact provider resume ID and directory")
            check(started["status"] == 0, "resumed foreground Agent rebinds through the production hook")
            current_id = str(uuid.uuid4())
            check(report({"hook_event_name": "SessionStart", "session_id": current_id, "cwd": str(project)})["status"] == 0,
                  "the same root Agent can establish a new provider conversation")
            check(report({"hook_event_name": "UserPromptSubmit", "session_id": current_id})["status"] == 0,
                  "work events follow the newly established conversation")
            check(report({"hook_event_name": "Stop", "session_id": session_id})["status"] != 0,
                  "a previous conversation Stop never completes the new turn")
            current = bridge.call("get", project, sessionId=resumed["sessionId"])["result"]
            check(current["conversation"]["sessionID"] == current_id and current["agentStatus"]["phase"] == "working",
                  "rejecting a previous Stop keeps the new identity and work state")
            check(report({"hook_event_name": "SessionEnd", "session_id": session_id})["status"] != 0,
                  "a previous conversation SessionEnd never clears the new session")
            check(report({"hook_event_name": "SessionEnd", "session_id": current_id})["status"] == 0
                  and bridge.call("get", project, sessionId=resumed["sessionId"])["result"]["conversation"] is None,
                  "the exact current SessionEnd still ends its own conversation")
        finally:
            try:
                bridge.call("shutdown", project)
            except (OSError, EOFError, ValueError, BrokenPipeError):
                pass
            bridge.close()
    print(f"{passed} remote Agent production checks passed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    options = parser.parse_args()
    main(str(options.binary.resolve()))
    from test_agent_fork import main as fork_checks
    fork_checks(str(options.binary.resolve()))
