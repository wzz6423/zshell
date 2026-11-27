"""Check Debug GUI and CLI startup against two private daemons with real PTYs."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--built-app", type=Path, required=True)
app = parser.parse_args().built_app.resolve()
cli = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]

with tempfile.TemporaryDirectory(prefix="zmux-", dir="/tmp") as directory:
    home = Path(directory)
    binary = home / "quit-tests"
    # Exercise the application's real entry-point dispatch and quit sweep.
    # Replacing only the window loop lets both daemons keep real PTYs offscreen.
    source = home / "main.swift"
    source.write_text("@testable import zshell\n" + (ROOT / "mac/zshell/main.swift").read_text() + """
private enum zshellApp {
    nonisolated static func main() {
        MainActor.assumeIsolated { TerminalManager.prepareForApplicationQuit() }
    }
}
""")
    command = compiler_arguments(home) + built_app_arguments(app)
    command.remove("-parse-as-library")
    subprocess.run(command + [str(source), "-o", str(binary)], check=True, timeout=120)
    (home / "tmp").mkdir()
    config = home / ".config/zshell-dev/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text("terminal.preserve-sessions = false\n")
    base = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
    base.update(CFFIXED_USER_HOME=str(home), HOME=str(home), ZDOTDIR=str(home),
                TMPDIR=str(home / "tmp") + "/", ZSHELL_SSH_AGENT_RESOLVED="1")
    support = home / "Library/Application Support"
    release = support / "zshell/pty-mux"
    debug = support / "zshell-dev/pty-mux"

    def mux(directory, *arguments):
        output = subprocess.check_output(cli + list(arguments), text=True, timeout=10,
                                         env=dict(base, ZSHELL_PTY_MUX_DIRECTORY=str(directory)))
        return json.loads(output)

    def wait_for_exit(directory, session_id):
        deadline = time.monotonic() + 3
        while mux(directory, "get", session_id)["running"]:
            if time.monotonic() >= deadline:
                raise AssertionError(f"Shell in {directory} is still running")
            time.sleep(0.05)

    sessions = {}
    try:
        for directory in (release, debug):
            session = mux(directory, "create", "--working-directory", str(home), "--",
                          "/bin/sh", "-c", "while IFS= read -r line; do :; done")
            sessions[directory] = session["id"]
        session_id = sessions[release]
        inherited = dict(base, ZSHELL_PTY_MUX_DIRECTORY=str(release), ZSHELL_TERMINAL_ID=session_id,
                         ZSHELL_PERSISTENT_CONNECTION=str(release / "sessions" / session_id / "connection.json"),
                         ZSHELL_PERSISTENT_TOKEN="fixture")
        listing = subprocess.check_output([str(binary), "+pty-mux", "list"], env=inherited, text=True, timeout=10)
        if [session["id"] for session in json.loads(listing)] != [session_id]:
            raise AssertionError("A CLI invocation lost its host shell's mux")
        subprocess.run([str(binary)], env=inherited, check=True, timeout=30)
        wait_for_exit(debug, sessions[debug])
        if not mux(release, "get", session_id)["running"]:
            raise AssertionError("Quitting Debug terminated the host shell")
        print("PASS: Debug quit ended its own retained shell and preserved the host shell. CLI still reached the host.")
        subprocess.run([str(binary)], env=dict(base, ZSHELL_PTY_MUX_DIRECTORY=str(release)), check=True, timeout=30)
        wait_for_exit(release, session_id)
        print("PASS: A GUI with an explicit private mux still used that directory.")
    finally:
        for directory, session_id in sessions.items():
            mux(directory, "terminate", session_id)
            wait_for_exit(directory, session_id)
            mux(directory, "shutdown")
