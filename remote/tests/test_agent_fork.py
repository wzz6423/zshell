"""Exercise native fork launch and independent identities through production remote PTYs.

Provider fixtures, HOME, daemon state and processes are disposable. This checks
Zshell's launch and ownership contract; test_native_agent_fork.py checks actual providers.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

from test_agents import Bridge, wait


def main(binary):
    checks = 0

    def check(condition, label):
        nonlocal checks
        assert condition, label
        checks += 1
        print("PASS " + label, flush=True)

    with tempfile.TemporaryDirectory(prefix="zs-agent-fork-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home, state, project, other, providers = [root / name for name in ("home", "state", "project", "other", "providers")]
        for path in (home, project, other, providers):
            path.mkdir(mode=0o700)
        fixture = Path(__file__).resolve().parents[2] / "mac/tests/fixtures/agent-conversation.py"
        for name in ("claude", "codex", "pi", "opencode"):
            path = providers / name
            shutil.copyfile(fixture, path)
            path.write_text("#!/usr/bin/env python3\n" + path.read_text())
            path.chmod(0o700)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("ZSHELL_") and key not in {
                           "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "CODEX_THREAD_ID",
                           "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_TUI_CONFIG",
                           "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                       }}
        environment.update(HOME=str(home), PATH=str(providers) + os.pathsep + "/usr/bin:/bin",
                           HISTORY_TEST_ROOT=str(root), HISTORY_TEST_REMOTE="1", HISTORY_TEST_SESSION=str(uuid.uuid4()))
        bridge = Bridge(binary, state, environment)
        try:
            check("agentFork" in bridge.call("hello", project)["result"]["capabilities"], "remote hello advertises native fork")
            for provider, variable in (("claude", "CLAUDE_CONFIG_DIR"), ("codex", "CODEX_HOME"),
                                       ("pi", "PI_CODING_AGENT_DIR"), ("opencode", "XDG_CONFIG_HOME")):
                session_id = str(uuid.uuid4())
                if provider == "opencode":
                    session_id = "ses_" + session_id
                profile = home / provider
                profile.mkdir()
                source_file = root / f"{provider}.jsonl"
                if provider == "pi":
                    source_file.write_text(json.dumps({"type": "session", "id": session_id, "cwd": str(project)}) + "\n")
                configured = {variable: str(profile), "HISTORY_TEST_SESSION": session_id,
                              "HISTORY_TEST_SESSION_FILE": str(source_file)}
                source_terminal = str(uuid.uuid4())
                source = bridge.call("create", project, sessionId=source_terminal,
                                     command=[str(providers / provider)], environment=configured)["result"]

                def info(terminal):
                    return bridge.call("get", project, sessionId=terminal)["result"]

                wait(lambda: info(source_terminal).get("conversation"))
                original = bridge.call("agentHistory", project)["result"]
                original = next(record for record in original if record["identity"]["sessionID"] == session_id)
                original_file = source_file.read_bytes() if provider == "pi" else None
                fork = bridge.call("agentFork", project, provider=provider, conversationId=session_id)["result"]
                fork_terminal = fork["sessionId"]
                check(fork_terminal != source_terminal and fork.get("conversation") is None,
                      f"{provider} forks to a new PTY without claiming the source identity")
                forked = wait(lambda: info(fork_terminal).get("conversation"))
                launched = json.loads((root / f"launch-{fork_terminal}.json").read_text())
                expected = ["--resume", session_id, "--fork-session"] if provider == "claude" else ["fork", session_id] if provider == "codex" \
                    else ["--fork", str(source_file)] if provider == "pi" else ["--session", session_id, "--fork"]
                check(launched["argv"] == expected and forked["sessionID"] != session_id,
                      f"{provider} uses exact native fork arguments and an independent conversation")
                check(launched["source_hook_status"] != 0, f"{provider} rejects the source identity in the pending fork")
                check(launched["configuration"][variable] == str(profile), f"{provider} restores the original profile")
                check(info(source_terminal)["running"] and info(source_terminal)["pid"] == source["pid"],
                      f"{provider} source PTY remains alive")
                retained = bridge.call("agentHistory", project)["result"]
                check(next(record for record in retained if record["identity"]["sessionID"] == session_id) == original,
                      f"{provider} source history remains unchanged")
                check("error" in bridge.call("agentFork", other, provider=provider, conversationId=session_id),
                      f"{provider} fork rejects a foreign project")
                if original_file is not None:
                    check(source_file.read_bytes() == original_file and forked["sessionFile"] != str(source_file),
                          "Pi fork uses a separate file and keeps its source intact")
                if provider == "codex":
                    check(not launched["inherited_codex_thread"], "Codex fork clears inherited thread identity")
                unsupported = root / "unsupported-fork"
                unsupported.touch()
                rejected = bridge.call("agentFork", project, provider=provider, conversationId=session_id)
                unsupported.unlink()
                check("error" in rejected and "native fork" in rejected["error"], f"{provider} rejects an older CLI before PTY creation")
                missing = providers / provider
                missing.rename(missing.with_suffix(".unavailable"))
                rejected = bridge.call("agentFork", project, provider=provider, conversationId=session_id)
                missing.with_suffix(".unavailable").rename(missing)
                check("error" in rejected and "not installed" in rejected["error"], f"{provider} missing CLI fails explicitly: {rejected}")
                bridge.call("terminate", project, sessionId=fork_terminal)
                bridge.call("terminate", project, sessionId=source_terminal)
        finally:
            try:
                bridge.call("shutdown", project)
            finally:
                bridge.close()
                subprocess.run([binary, "stop", "--state", str(state)], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
    print(f"{checks} remote fork production checks passed", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    main(str(parser.parse_args().binary.resolve()))
