"""Disposable provider process for the real conversation-history PTY tests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

provider = Path(sys.argv[0]).name
root = Path(os.environ["HISTORY_TEST_ROOT"])
terminal = os.environ["ZSHELL_TERMINAL_ID"]
session_id = os.environ["HISTORY_TEST_SESSION"]
session_file = os.environ.get("HISTORY_TEST_SESSION_FILE")
if "--session" in sys.argv:
    operand = sys.argv[sys.argv.index("--session") + 1]
    if provider == "pi":
        session_file = operand
        session_id = json.loads(Path(operand).read_text().splitlines()[0])["id"]
    else:
        session_id = operand
elif "--resume" in sys.argv:
    session_id = sys.argv[sys.argv.index("--resume") + 1]
elif "resume" in sys.argv:
    session_id = sys.argv[-1]

if provider == "codex":
    os.environ["CODEX_THREAD_ID"] = session_id

payload = {"hook_event_name": "SessionStart", "session_id": session_id, "cwd": os.getcwd()}
if provider == "pi":
    payload["session_file"] = session_file


def hook():
    subprocess.run([os.environ["ZSHELL_EXECUTABLE"], "+agent", "_session-start", provider],
                   input=json.dumps(payload), text=True, timeout=10, check=True)


(root / f"launch-{terminal}.json").write_text(json.dumps({
    "pid": os.getpid(), "pgid": os.getpgrp(), "argv": sys.argv[1:], "cwd": os.getcwd(),
    "session_id": session_id,
    "configuration": {key: value for key, value in os.environ.items() if key in {
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME",
        "XDG_DATA_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG",
        "OPENCODE_TUI_CONFIG",
    }},
}))
if not os.environ.get("HISTORY_TEST_NO_HOOK"):
    hook()
print(f"History fixture ready: {provider} {session_id}", flush=True)
request_path = root / f"command-{terminal}.json"
while not (root / f"stop-{terminal}").exists():
    if request_path.exists():
        request = json.loads(request_path.read_text())
        request_path.unlink()
        if request.get("hook"):
            hook()
            response = {"status": 0, "stdout": "hook", "stderr": ""}
        else:
            environment = dict(os.environ)
            if request.get("scrub"):
                environment = {key: value for key, value in environment.items()
                               if not key.startswith("ZSHELL_")}
            result = subprocess.run([os.environ["ZSHELL_EXECUTABLE"], *request["arguments"]],
                                    env=environment, text=True, capture_output=True, timeout=10)
            response = {"status": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        (root / f"response-{terminal}.json").write_text(json.dumps(response))
    time.sleep(0.02)
