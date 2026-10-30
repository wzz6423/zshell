"""Disposable provider process for the real conversation-history PTY tests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

provider = Path(sys.argv[0]).name
root = Path(os.environ["HISTORY_TEST_ROOT"])
if "--help" in sys.argv:
    if (root / "unsupported-fork").exists():
        print("Usage: provider --resume ID")
    elif (root / "slow-fork-help").exists():
        time.sleep(3)
    else:
        print("Usage: codex fork [SESSION_ID]" if provider == "codex"
              else " --fork-session" if provider == "claude" else " --fork <session>")
    sys.exit(0)
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

forking = "--fork" in sys.argv or "--fork-session" in sys.argv or "fork" in sys.argv
if forking:
    if provider == "codex":
        session_id = sys.argv[sys.argv.index("fork") + 1]
    if provider == "pi":
        session_file = sys.argv[sys.argv.index("--fork") + 1]
        session_id = json.loads(Path(session_file).read_text().splitlines()[0])["id"]
    source_id = session_id
    session_id = str(uuid.uuid4())
    if provider == "opencode":
        session_id = "ses_" + session_id
    if provider == "pi":
        entries = Path(session_file).read_text().splitlines()
        header = json.loads(entries[0])
        header.update(id=session_id, parentSession=session_file)
        session_file = str(root / f"fork-{session_id}.jsonl")
        Path(session_file).write_text(json.dumps(header) + "\n" + "\n".join(entries[1:]))

inherited_codex_thread = os.environ.get("CODEX_THREAD_ID")
if provider == "codex":
    os.environ["CODEX_THREAD_ID"] = session_id

payload = {"hook_event_name": "SessionStart", "session_id": session_id, "cwd": os.getcwd()}
if provider == "pi":
    payload["session_file"] = session_file


def hook():
    arguments = ["hook", provider] if os.environ.get("HISTORY_TEST_REMOTE") else ["+agent", "_session-start", provider]
    return subprocess.run([os.environ["ZSHELL_EXECUTABLE"], *arguments],
                          input=json.dumps(payload), text=True, timeout=10)


source_hook_status = None
if forking:
    payload["session_id"] = source_id
    if provider == "codex":
        os.environ["CODEX_THREAD_ID"] = source_id
    source_hook_status = hook().returncode
    payload["session_id"] = session_id
    if provider == "codex":
        os.environ["CODEX_THREAD_ID"] = session_id
    if os.environ.get("HISTORY_TEST_NO_FORK_HOOK"):
        payload["session_id"] = source_id
        if provider == "codex":
            os.environ["CODEX_THREAD_ID"] = source_id


(root / f"launch-{terminal}.json").write_text(json.dumps({
    "pid": os.getpid(), "pgid": os.getpgrp(), "argv": sys.argv[1:], "cwd": os.getcwd(),
    "session_id": session_id,
    "source_hook_status": source_hook_status,
    "inherited_codex_thread": inherited_codex_thread,
    "configuration": {key: value for key, value in os.environ.items() if key in {
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME",
        "XDG_DATA_HOME", "XDG_STATE_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG",
        "OPENCODE_TUI_CONFIG",
    }},
}))
if forking:
    while (root / "pause-fork-hook").exists() and not (root / f"stop-{terminal}").exists():
        time.sleep(0.02)
if not os.environ.get("HISTORY_TEST_NO_HOOK"):
    if hook().returncode:
        sys.exit(1)
print(f"History fixture ready: {provider} {session_id}", flush=True)
request_path = root / f"command-{terminal}.json"
while not (root / f"stop-{terminal}").exists():
    if request_path.exists():
        request = json.loads(request_path.read_text())
        request_path.unlink()
        if request.get("hook"):
            response = {"status": hook().returncode, "stdout": "hook", "stderr": ""}
        else:
            environment = dict(os.environ)
            if request.get("scrub"):
                environment = {key: value for key, value in environment.items()
                               if not key.startswith("ZSHELL_")}
            result = subprocess.run([os.environ["ZSHELL_EXECUTABLE"], *request["arguments"]],
                                    env=environment, text=True, capture_output=True, timeout=45)
            response = {"status": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        (root / f"response-{terminal}.json").write_text(json.dumps(response))
    time.sleep(0.02)
