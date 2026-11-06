"""Exercise installed Claude/Codex through production local surfaces and sockets.

Set ZSHELL_TEST_DERIVED_DATA to a Debug build and ZSHELL_TEST_NATIVE_CLAUDE /
ZSHELL_TEST_NATIVE_CODEX to installed executables. Their HOME, provider settings,
projects, hooks, PTYs, app preferences and compiled probe are disposable. All
model requests use a localhost streaming fixture; no account or paid API is used.
Claude is checked both as a direct startup command and inside a normal zsh job.
"""

import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import signal
import subprocess
import tempfile
import threading
import uuid


root = Path(__file__).resolve().parents[2]
build = Path(os.environ["ZSHELL_TEST_DERIVED_DATA"]) / "Build"
products = build / "Products/Debug"
app = products / "zshell Debug.app/Contents"
library = app / "MacOS/zshell.debug.dylib"
providers = {provider: os.environ[f"ZSHELL_TEST_NATIVE_{provider.upper()}"]
             for provider in ("claude", "codex")}
if not library.is_file():
    raise SystemExit(f"Build the Debug app in {build.parent} before running native interrupt checks.")
for provider, executable in providers.items():
    if not Path(executable).is_file():
        raise SystemExit(f"ZSHELL_TEST_NATIVE_{provider.upper()} must point to an installed executable.")


class StreamingFixture:
    def __init__(self, directory, provider):
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.streams = 0
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def json(self, value):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(value).encode())

            def do_GET(self):
                self.json({"data": []})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                if "count_tokens" in self.path:
                    self.json({"input_tokens": 10})
                    return
                if provider == "claude" and not body.get("stream"):
                    self.json({"id": "msg_fixture", "type": "message", "role": "assistant",
                               "model": "claude-sonnet-4-6", "content": [{"type": "text", "text": "LOCAL_FIXTURE"}],
                               "stop_reason": "end_turn", "stop_sequence": None,
                               "usage": {"input_tokens": 10, "output_tokens": 2}})
                    return
                with fixture.lock:
                    fixture.streams += 1
                    index = fixture.streams
                    (directory / f"stream-{index}").touch()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                if provider == "claude":
                    events = [
                        {"type": "message_start", "message": {
                            "id": f"msg_fixture_{index}", "type": "message", "role": "assistant",
                            "model": "claude-sonnet-4-6", "content": [], "stop_reason": None,
                            "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}},
                        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                    ]
                else:
                    events = [
                        {"type": "response.created", "response": {
                            "id": f"resp_fixture_{index}", "object": "response", "status": "in_progress",
                            "model": "gpt-4.1", "output": []}},
                        {"type": "response.output_item.added", "output_index": 0, "item": {
                            "id": f"msg_fixture_{index}", "type": "message", "role": "assistant", "content": []}},
                        {"type": "response.content_part.added", "item_id": f"msg_fixture_{index}",
                         "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": ""}},
                    ]
                try:
                    for event in events:
                        if provider == "claude":
                            self.wfile.write(("event: " + event["type"] + "\n").encode())
                        self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                        self.wfile.flush()
                    while not fixture.stop.wait(0.25):
                        self.wfile.write(b": local keepalive\n\n")
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.stop.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def environment_for(home, directory):
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("ZSHELL_", "CLAUDE_", "ANTHROPIC_", "CODEX_", "OPENAI_", "PI_", "OPENCODE_"))
                   and key not in {"XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "ZDOTDIR", "CFFIXED_USER_HOME"}}
    environment.update({
        "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"), "NATIVE_INTERRUPT_ROOT": str(directory),
        "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty-mux"), "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
    })
    return environment


def configure(provider, executable, home, project, fixture, hook, environment):
    command = "/usr/bin/python3 " + shlex.quote(str(hook)) + " " + provider
    if provider == "claude":
        config = home / ".claude"
        config.mkdir()
        (config / ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "theme": "dark", "numStartups": 2,
            "projects": {str(project.resolve()): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}},
            "customApiKeyResponses": {"approved": ["sk-ant-local-fixture"], "rejected": []},
        }))
        events = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "SubagentStart", "SubagentStop"]
        (config / "settings.json").write_text(json.dumps({
            "skipDangerousModePermissionPrompt": True,
            "hooks": {event: [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 15}]}]
                      for event in events},
        }))
        environment.update(CLAUDE_CONFIG_DIR=str(config), ANTHROPIC_API_KEY="sk-ant-local-fixture",
                           ANTHROPIC_BASE_URL=fixture.url, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
        return [executable, "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--no-chrome", "--permission-mode", "bypassPermissions", "--model", "claude-sonnet-4-6"]
    config = home / ".codex"
    config.mkdir()
    (config / "config.toml").write_text(
        'model = "gpt-4.1"\nmodel_provider = "fixture"\n'
        + "[projects." + json.dumps(str(project.resolve())) + ']\ntrust_level = "trusted"\n'
        + '[model_providers.fixture]\nname = "Fixture"\nbase_url = ' + json.dumps(fixture.url + "/v1")
        + '\nwire_api = "responses"\nrequires_openai_auth = false\n[features]\ncodex_hooks = true\n'
    )
    events = ["SessionStart", "UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"]
    (config / "hooks.json").write_text(json.dumps({
        "hooks": {event: [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 15}]}]
                  for event in events},
    }))
    environment["CODEX_HOME"] = str(config)
    return [executable, "--no-daemon", "--no-alt-screen", "--dangerously-bypass-hook-trust",
            "-a", "never", "-s", "read-only", "-C", str(project), "Wait for the local API. Probe 1."]


def stop_owned_processes(directory):
    listing = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, check=True).stdout
    rows = {}
    for line in listing.splitlines():
        values = line.strip().split(maxsplit=2)
        if len(values) == 3:
            rows[int(values[0])] = (int(values[1]), values[2])
    owned = {pid for pid, (_, command) in rows.items() if str(directory) in command and pid != os.getpid()}
    while True:
        children = {pid for pid, (parent, _) in rows.items() if parent in owned}
        if children.issubset(owned):
            break
        owned.update(children)
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


with tempfile.TemporaryDirectory(prefix="zshell-native-interrupt-tests-", dir="/tmp") as temporary:
    directory = Path(temporary)
    contents = directory / "NativeInterrupt.app/Contents"
    binary = contents / "MacOS/zshell"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Resources")
    domain = "sh.zshell.native-interrupt." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": domain, "CFBundleExecutable": "zshell", "CFBundlePackageType": "APPL",
        "CFBundleDevelopmentRegion": "en", "LSUIElement": True,
    }))
    hook = directory / "hook.py"
    hook.write_text('''import json, os, subprocess, sys
from pathlib import Path
root = Path(os.environ["NATIVE_INTERRUPT_ROOT"])
provider = sys.argv[1]
raw = sys.stdin.buffer.read()
event = json.loads(raw)
with (root / "hooks.jsonl").open("a") as file:
    file.write(json.dumps({"event": event}) + "\\n")
binary = os.environ["ZSHELL_EXECUTABLE"]
if event.get("hook_event_name") == "SessionStart":
    subprocess.run([binary, "+agent", "_session-start", provider], input=raw, capture_output=True, timeout=8)
subprocess.run([binary, "+agent", "_lifecycle", provider], input=raw, capture_output=True, timeout=8)
''')
    arguments = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-name", "NativeAgentInterruptTests",
        "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(directory / "ModuleCache"),
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
        "-I", str(root / "mac/Vendor/alacritty-bridge/include"), "-I", str(root / "mac/Vendor/tree-sitter/lib/include"),
        str(library), "-Xlinker", "-rpath", "-Xlinker", str(products), "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
        str(root / "mac/tests/NativeAgentInterruptTests.swift"), str(root / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(arguments, cwd=root, check=True)
    for provider, style in (("claude", "direct"), ("claude", "shell"), ("codex", "direct")):
        for backend in ("alacritty", "ghostty"):
            case = directory / f"{provider}-{style}-{backend}"
            case.mkdir()
            home = case / "home"
            home.mkdir()
            project = case / "project"
            project.mkdir()
            subprocess.run(["git", "init", "-q", str(project)], check=True)
            (project / "fixture.txt").write_text("Native interrupt fixture.\n")
            subprocess.run(["git", "-C", str(project), "add", "fixture.txt"], check=True)
            subprocess.run(["git", "-C", str(project), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "-q", "-m", "Fixture"], check=True)
            fixture = StreamingFixture(case, provider)
            environment = environment_for(home, case)
            launch = configure(provider, providers[provider], home, project, fixture, hook, environment)
            if style == "shell":
                (home / ".zshrc").write_text("unset HISTFILE\n")
                (case / "shell-command").write_text(shlex.join(launch))
                launch = ["/bin/zsh", "-l"]
            (case / "launch.json").write_text(json.dumps(launch))
            print(f"RUN native {provider} {style} {backend}", flush=True)
            try:
                subprocess.run([str(binary), backend, provider, str(case)], cwd=project,
                               env=environment, check=True, timeout=150)
            finally:
                fixture.close()
                stop_owned_processes(case)
                if (home / "pty-mux/control.sock").exists():
                    subprocess.run([str(binary), "+pty-mux", "shutdown"], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
