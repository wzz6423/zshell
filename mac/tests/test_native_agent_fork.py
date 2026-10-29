"""Verify installed providers retain native context when forking disposable sessions.

Run with --providers codex claude opencode pi (the default) or select a subset.
Codex/OpenCode use their native local server APIs, Claude uses its real CLI and a
loopback model fixture, and Pi uses its real RPC CLI. No user account is required.
These probes do not replace the production pane tests in test_agent_conversation_history.py.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid


MARKER = "Native context: amber otter 873."
STAMP = "2026-10-28T12:00:00Z"


def isolated_environment(home):
    return {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "dumb", "NO_COLOR": "1",
            "NO_PROXY": "127.0.0.1,localhost", "PI_OFFLINE": "1"}


def write_jsonl(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))


class JSONProcess:
    def __init__(self, arguments, environment, cwd, log):
        self.log = log.open("w")
        self.process = subprocess.Popen(arguments, env=environment, cwd=cwd, text=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.responses = queue.Queue()

        def read():
            for line in self.process.stdout:
                try:
                    self.responses.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
            self.responses.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def request(self, value, timeout=15):
        self.send(value)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.responses.get(timeout=max(0.01, deadline - time.monotonic()))
            if response is None:
                raise AssertionError("Provider exited before its fork response")
            if response.get("id") == value["id"]:
                return response
        raise AssertionError("Provider fork response timed out")

    def close(self):
        self.process.stdin.close()
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.reader.join(timeout=1)
        self.process.stdout.close()
        self.log.close()


def codex_probe(binary, root, environment, cwd):
    home = Path(environment["HOME"])
    environment.update(CODEX_HOME=str(home))
    (home / "config.toml").write_text('model = "gpt-4.1"\nmodel_provider = "fixture"\n'
        '[model_providers.fixture]\nname = "Fixture"\nbase_url = "http://127.0.0.1:9/v1"\n'
        'wire_api = "responses"\nrequires_openai_auth = false\n')
    source_id = str(uuid.uuid4())
    path = home / "sessions/2026/10/28" / f"rollout-2026-10-28T12-00-00-{source_id}.jsonl"
    native = [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": MARKER}]},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Remembered."}]},
        {"type": "function_call", "name": "exec_command", "arguments": '{"cmd":"echo amber"}', "call_id": "fixture-call"},
        {"type": "function_call_output", "call_id": "fixture-call", "output": "amber\n"},
    ]
    meta = {"id": source_id, "timestamp": STAMP, "cwd": str(cwd), "originator": "codex",
            "cli_version": "0.165.0", "source": "cli", "model_provider": "fixture",
            "base_instructions": {"text": "Keep the native instructions marker."}}
    write_jsonl(path, [{"timestamp": STAMP, "type": "session_meta", "payload": meta}]
                + [{"timestamp": STAMP, "type": "response_item", "payload": value} for value in native])
    original = path.read_bytes()
    process = JSONProcess([binary, "app-server", "--listen", "stdio://"], environment, cwd, root / "codex.log")
    try:
        initialized = process.request({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "zshell-fork-fixture", "version": "1"}, "capabilities": {"experimentalApi": True}}})
        assert "result" in initialized, initialized
        process.send({"method": "initialized"})
        response = process.request({"id": 2, "method": "thread/fork", "params": {"threadId": source_id, "cwd": str(cwd)}})
        assert "result" in response, response
        fork = response["result"]["thread"]
        assert fork["id"] != source_id and fork["forkedFromId"] == source_id
        fork_file = Path(fork["path"])
        entries = [json.loads(line) for line in fork_file.read_text().splitlines()]
        messages = [{key: value for key, value in item["payload"].items() if key != "id"}
                    for item in entries if item["type"] == "response_item"]
        assert messages[:len(native)] == native, "Codex native message/tool context changed"
        assert entries[0]["payload"]["base_instructions"] == meta["base_instructions"]
        assert fork_file != path and path.read_bytes() == original, "Codex fork changed its source"
    finally:
        process.close()


def claude_probe(binary, root, environment, cwd):
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            requests.append(body)
            result = {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant",
                      "model": "claude-sonnet-4-6", "content": [{"type": "text", "text": "FORK_FIXTURE_OK"}],
                      "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 2}}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream" if body.get("stream") else "application/json")
            self.end_headers()
            if not body.get("stream"):
                self.wfile.write(json.dumps(result).encode())
                return
            events = [
                ("message_start", {"type": "message_start", "message": {**result, "content": [], "stop_reason": None}}),
                ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "FORK_FIXTURE_OK"}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 2}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            for event, data in events:
                self.wfile.write(("event: " + event + "\ndata: " + json.dumps(data) + "\n\n").encode())

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = Path(environment["HOME"]) / ".claude"
    config.mkdir()
    environment.update(CLAUDE_CONFIG_DIR=str(config), ANTHROPIC_API_KEY="fixture-test-key",
                       ANTHROPIC_BASE_URL=f"http://127.0.0.1:{server.server_port}", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
    source_id = str(uuid.uuid4())
    project = "".join(character if character.isalnum() else "-" for character in str(cwd.resolve()))
    path = config / "projects" / project / f"{source_id}.jsonl"
    user_id, assistant_id, tool_id = [str(uuid.uuid4()) for _ in range(3)]
    common = {"isSidechain": False, "userType": "external", "cwd": str(cwd), "sessionId": source_id,
              "version": "2.1.312", "timestamp": STAMP}
    native = [
        {**common, "parentUuid": None, "uuid": user_id, "type": "user", "message": {"role": "user", "content": MARKER}},
        {**common, "parentUuid": user_id, "uuid": assistant_id, "type": "assistant", "message": {
            "id": "msg_fixture", "type": "message", "role": "assistant", "model": "claude-sonnet-4-6",
            "content": [{"type": "text", "text": "Remembered."}, {"type": "tool_use", "id": "tool_fixture", "name": "Bash", "input": {"command": "echo amber"}}],
            "stop_reason": "tool_use", "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}},
        {**common, "parentUuid": assistant_id, "uuid": tool_id, "type": "user", "message": {
            "role": "user", "content": [{"type": "tool_result", "tool_use_id": "tool_fixture", "content": "amber\n"}]}},
    ]
    write_jsonl(path, native)
    original = path.read_bytes()
    try:
        result = subprocess.run([binary, "--print", "--resume", source_id, "--fork-session", "--output-format", "json",
            "--model", "claude-sonnet-4-6", "--tools", "", "--setting-sources", "", "--no-chrome", "Reply without tools."],
            env=environment, cwd=cwd, capture_output=True, text=True, timeout=30, check=True)
        fork = json.loads(result.stdout)
        assert fork["session_id"] != source_id and path.read_bytes() == original
        assert any(MARKER in json.dumps(request.get("messages")) and "tool_fixture" in json.dumps(request.get("messages"))
                   and "amber\\n" in json.dumps(request.get("messages")) for request in requests), "Claude did not send native tool context"
    finally:
        server.shutdown()
        server.server_close()


def opencode_probe(binary, root, environment, cwd):
    home = Path(environment["HOME"])
    environment.update(XDG_CONFIG_HOME=str(home / "config"), XDG_DATA_HOME=str(home / "data"), XDG_STATE_HOME=str(home / "state"))
    source_id = "ses_fixture" + uuid.uuid4().hex
    # OpenCode's message IDs define chronology and assistant parent remapping.
    user_id, assistant_id = "msg_10000000000000000000000001", "msg_10000000000000000000000002"
    at = int(time.time() * 1000)
    fixture = {"info": {"id": source_id, "slug": "fixture", "version": "1.19.4", "projectID": "global",
                        "directory": str(cwd), "title": "Native context", "time": {"created": at, "updated": at}}, "messages": [
        {"info": {"id": user_id, "sessionID": source_id, "role": "user", "time": {"created": at}, "agent": "build",
                  "model": {"providerID": "fixture", "modelID": "fixture"}}, "parts": [{"id": "prt_10000000000000000000000001",
                  "sessionID": source_id, "messageID": user_id, "type": "text", "text": MARKER}]},
        {"info": {"id": assistant_id, "sessionID": source_id, "role": "assistant", "parentID": user_id,
                  "time": {"created": at + 1, "completed": at + 2}, "modelID": "fixture", "providerID": "fixture",
                  "mode": "build", "agent": "build", "path": {"cwd": str(cwd), "root": str(cwd)}, "cost": 0,
                  "tokens": {"input": 1, "output": 1, "reasoning": 0, "cache": {"read": 0, "write": 0}}, "finish": "stop"}, "parts": [
            {"id": "prt_10000000000000000000000002", "sessionID": source_id, "messageID": assistant_id, "type": "text", "text": "Remembered."},
            {"id": "prt_10000000000000000000000003", "sessionID": source_id, "messageID": assistant_id, "type": "tool", "tool": "bash",
             "callID": "fixture-call", "state": {"status": "completed", "input": {"command": "echo amber"}, "output": "amber\n",
                                                   "title": "echo amber", "metadata": {}, "time": {"start": at, "end": at + 2}}}]}]}
    fixture_path = root / "opencode-fixture.json"
    fixture_path.write_text(json.dumps(fixture))
    subprocess.run([binary, "import", str(fixture_path)], env=environment, cwd=cwd, capture_output=True, text=True, timeout=15, check=True)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with (root / "opencode.log").open("w") as log:
        process = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", str(port)], env=environment, cwd=cwd, stdout=log, stderr=log)

        def call(path, payload=None):
            request = urllib.request.Request(f"http://127.0.0.1:{port}" + path,
                data=None if payload is None else json.dumps(payload).encode(), headers={"Content-Type": "application/json", "x-opencode-directory": str(cwd)})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)

        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    original = call(f"/session/{source_id}/message")
                    break
                except (OSError, ValueError):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.1)
            fork = call(f"/session/{source_id}/fork", {})
            forked = call(f"/session/{fork['id']}/message")
            assert fork["id"] != source_id and call(f"/session/{source_id}/message") == original
            assert len(forked) == 2 and [item["info"]["role"] for item in forked] == ["user", "assistant"]
            assert forked[1]["info"]["parentID"] == forked[0]["info"]["id"], "OpenCode fork lost parent mapping"
            for before, after in zip(original, forked):
                assert before["info"]["id"] != after["info"]["id"]
                clean = lambda part: {key: value for key, value in part.items() if key not in {"id", "sessionID", "messageID"}}
                assert [clean(part) for part in before["parts"]] == [clean(part) for part in after["parts"]]
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)


def prepare_pi_fixture(root, cwd):
    source_id = str(uuid.uuid4())
    path = root / "pi-source.jsonl"
    usage = {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 2,
             "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}
    entries = [
        {"type": "session", "version": 3, "id": source_id, "timestamp": STAMP, "cwd": str(cwd)},
        {"type": "message", "id": "11111111", "parentId": None, "timestamp": STAMP,
         "message": {"role": "user", "content": MARKER, "timestamp": 1}},
        {"type": "message", "id": "22222222", "parentId": "11111111", "timestamp": STAMP, "message": {
            "role": "assistant", "content": [{"type": "thinking", "thinking": "Retain reasoning"},
                {"type": "toolCall", "id": "fixture-call", "name": "bash", "arguments": {"command": "echo amber"}}],
            "api": "openai-responses", "provider": "openai", "model": "fixture", "usage": usage, "stopReason": "toolUse", "timestamp": 2}},
        {"type": "message", "id": "33333333", "parentId": "22222222", "timestamp": STAMP, "message": {
            "role": "toolResult", "toolCallId": "fixture-call", "toolName": "bash", "content": [{"type": "text", "text": "amber\n"}], "isError": False, "timestamp": 3}},
        {"type": "custom", "id": "44444444", "parentId": "33333333", "timestamp": STAMP, "customType": "fork-fixture", "data": {"native": True}},
    ]
    write_jsonl(path, entries)
    return source_id, path, entries


def pi_probe(binary, root, environment, cwd):
    environment.update(PI_CODING_AGENT_DIR=str(Path(environment["HOME"]) / "agent"))
    source_id, path, entries = prepare_pi_fixture(root, cwd)
    original = path.read_bytes()
    process = JSONProcess([binary, "--fork", str(path), "--mode", "rpc", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"],
                          environment, cwd, root / "pi.log")
    try:
        response = process.request({"id": "state", "type": "get_state"})
        assert response.get("success"), response
        state = response["data"]
        assert state["sessionId"] != source_id and state["sessionFile"] != str(path)
        fork_file = Path(state["sessionFile"])
        forked = [json.loads(line) for line in fork_file.read_text().splitlines()]
        assert forked[0]["parentSession"] == str(path) and forked[1:len(entries)] == entries[1:], forked
        messages = process.request({"id": "messages", "type": "get_messages"})
        assert messages["success"] and messages["data"]["messages"] == [entry["message"] for entry in entries if entry["type"] == "message"]
        assert path.read_bytes() == original
    finally:
        process.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--providers", nargs="+", choices=["codex", "claude", "opencode", "pi"], default=["codex", "claude", "opencode", "pi"])
    options = parser.parse_args()
    for provider in options.providers:
        binary = shutil.which(provider)
        if binary is None:
            raise SystemExit(f"Install {provider} or select the available providers with --providers")
        with tempfile.TemporaryDirectory(prefix=f"zshell-native-fork-{provider}-", dir="/tmp") as temporary:
            root = Path(temporary).resolve()
            home, cwd = root / "home", root / "project"
            home.mkdir()
            cwd.mkdir()
            globals()[provider + "_probe"](binary, root, isolated_environment(home), cwd)
        print(f"PASS actual {provider} native fork: independent ID, native context/tools retained, source unchanged", flush=True)
