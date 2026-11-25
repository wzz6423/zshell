"""Exercise the original local Bash hooks with real, disposable macOS PTYs.

Run: python3 mac/tests/test_bash_command_tasks.py [--bash /absolute/path/to/bash]
Only test-owned homes, processes, result files and binaries are created.
"""

import argparse
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "mac/zshell"
BASH = "/bin/bash"


class BashCommandTaskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-bash-task-build-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        root = Path(cls.build.name)
        helper = root / "main.swift"
        helper.write_text(r'''
import Foundation
import Darwin
let args = CommandLine.arguments
if args[1] == "argv" {
    print(TerminalBashShellIntegration.interactiveArguments(Array(args.dropFirst(2))))
} else if args[1] == "clean" {
    print(TerminalBashShellIntegration.inputIsClean(promptSequence: UInt64(args[2])!, inputSequence: args[3] == "nil" ? nil : UInt64(args[3])))
} else if args[1] == "ready" {
    print(TerminalBashShellIntegration.readPromptSequence(shellPID: pid_t(args[3])!, directory: URL(fileURLWithPath: args[2])).map(String.init) ?? "nil")
} else if args[1] == "persistent-clean" {
    print(TerminalBashShellIntegration.persistentInputIsClean(shellPID: pid_t(args[3])!, directory: URL(fileURLWithPath: args[2]), promptSequence: UInt64(args[4])!))
} else if args[1] == "persistent-input" {
    print(TerminalBashShellIntegration.recordPersistentInput(shellPID: pid_t(args[3])!, directory: URL(fileURLWithPath: args[2])))
} else if args[1] == "result" {
    let id = UUID(uuidString: args[3])!
    if let result = TerminalCommandTaskShellResult.read(taskID: id, shellPID: pid_t(args[4])!, directory: URL(fileURLWithPath: args[2])) {
        var task = TerminalCommandTask(id: id, projectID: UUID(), paneID: UUID(), terminalID: UUID(), argv: ["fixture"])
        task.start()
        precondition(task.observeCompletion(sequence: 2, shellResult: result, output: { "output" }))
        print(String(decoding: try JSONEncoder().encode(task.json), as: UTF8.self))
    } else { print("null") }
} else {
    let directory = URL(fileURLWithPath: args[2])
    _ = try TerminalBashShellIntegration.makeArtifacts(in: directory)
    print(TerminalBashShellIntegration.bootstrap(in: directory, initialization: args.count > 3 ? args[3] : nil))
}
''')
        cls.helper = root / "helper"
        subprocess.run(["swiftc", str(helper), str(SOURCE / "TerminalBashShellIntegration.swift"),
                        str(SOURCE / "TerminalCommandTask.swift"), str(SOURCE / "TerminalCommandTaskShellIntegration.swift"),
                        str(SOURCE / "ZshellAutomationProtocol.swift"), "-o", str(cls.helper)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zshell-bash-tasks-'", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.tasks = self.root / "command-tasks"
        self.tasks.mkdir()
        self.fd = None
        self.pid = None
        self.addCleanup(self.close_shell)

    def probe(self, *arguments):
        return subprocess.check_output([str(self.helper), *map(str, arguments)], text=True).strip()

    def start_shell(self, rc="", initialization=None, prompt_command="", flags=("-il",), backend="alacritty"):
        shutil.rmtree(self.root / "bash-integration", ignore_errors=True)
        (self.root / "command-task-ready.pid").unlink(missing_ok=True)
        startup_file = ".bash_profile" if "l" in "".join(flags) else ".bashrc"
        (self.home / startup_file).write_text("HISTFILE=/dev/null\nPS1='BASH_READY> '\nPS2='BASH_MORE> '\n" + rc)
        bootstrap = self.probe("generate", self.root, *([] if initialization is None else [initialization]))
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("ZSHELL_", "GHOSTTY_")) and key not in ("PROMPT_COMMAND", "BASH_ENV", "ENV")}
        environment.update(HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), TERM="xterm-256color",
                           LC_ALL="en_US.UTF-8", BASH_SILENCE_DEPRECATION_WARNING="1", ZSHELL_TERM=backend,
                           PROMPT_COMMAND=prompt_command)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.root)
            os.environ.clear()
            os.environ.update(environment)
            os.execv("/bin/sh", ["sh", "-c", bootstrap + "; exec " + shlex.join([BASH, *flags])])
        return self.read_until(lambda output: b"BASH_READY> " in output)

    def close_shell(self):
        if self.fd is None:
            return
        os.close(self.fd)
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        self.fd = None

    def read_until(self, predicate, timeout=5):
        output = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], .02)[0]:
                output += os.read(self.fd, 65536)
            if predicate(output):
                while select.select([self.fd], [], [], .03)[0]:
                    output += os.read(self.fd, 65536)
                return output
        self.fail(f"Bash PTY timed out: {output!r}")

    def command(self, command):
        os.write(self.fd, command.encode() + b"\r")
        return self.read_until(lambda output: b"BASH_READY> " in output)

    def sequence(self):
        value = self.probe("ready", self.root, self.pid)
        return None if value == "nil" else int(value)

    def task(self, argv, status):
        task_id = str(uuid.uuid4()).upper()
        output = self.command(shlex.join(["_zshell_command_task", task_id, *argv]))
        self.assertEqual(output.count(b"\x1b]133;C\x07"), 1)
        self.assertEqual(output.count(f"\x1b]133;D;{status}\x07".encode()), 1)
        snapshot = json.loads(self.probe("result", self.tasks, task_id, self.pid))
        self.assertEqual(snapshot["state"], "completed")
        self.assertEqual(snapshot["exit_code"], status)
        self.assertGreaterEqual(snapshot["duration_ms"], 0)
        repeated = json.loads(self.probe("result", self.tasks, task_id, self.pid))
        self.assertEqual(repeated["task_id"], task_id)
        self.assertEqual(repeated["exit_code"], status)
        return task_id, output

    def test_success_failure_multiline_and_quoted_arguments(self):
        for backend in ("alacritty", "ghostty"):
            with self.subTest(backend=backend):
                self.start_shell(backend=backend)
                self.assertEqual(self.sequence(), 1)
                self.task(["/usr/bin/true"], 0)
                self.task(["/usr/bin/false"], 1)
                self.task(["/bin/sh", "-c", "printf 'line1\\nline2\\n'; exit 7"], 7)
                _, output = self.task(["/usr/bin/printf", "<%s>\\n", "quote' 中文; $(false) `false`"], 0)
                self.assertIn("quote' 中文; $(false) `false`".encode(), output)
                self.close_shell()

    def test_prompt_hooks_run_once_preserve_order_and_command_status(self):
        rc = "_user_prompt() { printf 'USER_STATUS:%s\\n' \"$?\"; true; }; PROMPT_COMMAND=\"$PROMPT_COMMAND; _user_prompt\"\n"
        startup = self.start_shell(rc=rc, prompt_command="printf OLD")
        self.assertEqual(startup.count(b"OLD"), 1)
        self.assertNotIn(b"\x1b]133;C", startup)
        output = self.command("false")
        self.assertNotIn(b"\x1b]133;D", output)
        self.assertEqual(output.count(b"OLD"), 1)
        self.assertIn(b"USER_STATUS:0", output)
        self.assertLess(output.index(b"OLD"), output.index(b"USER_STATUS"))
        self.task(["/bin/sh", "-c", "exit 7"], 7)

    def test_debug_and_signal_traps_keep_original_behavior(self):
        rc = "trap 'printf \"DEBUG_STATUS:%s\\n\" \"$?\"' DEBUG\ntrap 'printf USER_INT' INT\n"
        self.start_shell(rc=rc)
        output = self.command("false")
        self.assertIn(b"DEBUG_STATUS:1", output)
        self.assertNotIn(b"\x1b]133;D", output)
        self.assertNotIn(b"\x1b]133;C", output)
        self.task(["/usr/bin/true"], 0)
        output = self.command("trap -p INT")
        self.assertIn(b"trap -- 'printf USER_INT' SIGINT", output)

    def test_ctrl_c_publishes_status_130_atomically(self):
        self.start_shell()
        task_id = str(uuid.uuid4()).upper()
        os.write(self.fd, shlex.join(["_zshell_command_task", task_id, "/bin/sleep", "10"]).encode() + b"\r")
        self.read_until(lambda output: b"\x1b]133;C\x07" in output)
        os.write(self.fd, b"\x03")
        output = self.read_until(lambda output: b"BASH_READY> " in output)
        self.assertIn(b"\x1b]133;D;130\x07", output)
        snapshot = json.loads(self.probe("result", self.tasks, task_id, self.pid))
        self.assertEqual(snapshot["exit_code"], 130)
        self.assertFalse((self.tasks / (task_id + ".part")).exists())

    def test_initialization_keeps_login_files_state_and_logout(self):
        logout = self.home / "logout"
        (self.home / ".bash_logout").write_text("printf LOGOUT > " + shlex.quote(str(logout)) + "\n")
        rc = "export LOGIN_VALUE=profile; alias fixture_alias='printf ALIAS_VALUE'\n"
        self.start_shell(rc=rc, initialization="export INIT_VALUE=initialized; false")
        output = self.command("printf '%s:%s\\n' \"$LOGIN_VALUE\" \"$INIT_VALUE\"; shopt -q login_shell; printf 'login:%s\\n' \"$?\"; fixture_alias")
        self.assertIn(b"profile:initialized", output)
        self.assertIn(b"login:0", output)
        self.assertIn(b"ALIAS_VALUE", output)
        os.write(self.fd, b"exit\r")
        deadline = time.monotonic() + 3
        while not logout.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(logout.read_text(), "LOGOUT")

    def test_overwritten_prompt_command_and_disabled_promptvars_stay_unsupported(self):
        for rc in ("PROMPT_COMMAND='true'\n", "unset PROMPT_COMMAND\n", "shopt -u promptvars\n", "shopt -s extdebug\n"):
            with self.subTest(rc=rc):
                self.start_shell(rc=rc)
                self.assertIsNone(self.sequence())
                self.assertNotIn(b"\x1b]133;C", self.command("false"))
                self.close_shell()

    def test_nested_shell_does_not_duplicate_results(self):
        self.start_shell()
        original = self.sequence()
        output = self.command("/bin/bash --noprofile --norc -ic 'printf NESTED; false'")
        self.assertNotIn(b"\x1b]133;C", output)
        self.assertNotIn(b"\x1b]133;D", output)
        self.assertEqual(self.sequence(), original + 1)

    def test_parenthesized_manual_command_keeps_native_status(self):
        self.start_shell()
        before = self.sequence()
        output = self.command("(printf SUBSHELL; false)")
        self.assertIn(b"SUBSHELL", output)
        self.assertNotIn(b"\x1b]133;C", output)
        self.assertNotIn(b"\x1b]133;D", output)
        output = self.command("printf 'NATIVE_STATUS:%s\\n' \"$?\"")
        self.assertIn(b"NATIVE_STATUS:1", output)

    def test_empty_prompt_and_multiline_input_emit_one_completion(self):
        self.start_shell()
        before = self.sequence()
        output = self.command("")
        self.assertNotIn(b"\x1b]133;C", output)
        self.assertNotIn(b"\x1b]133;D", output)
        self.assertEqual(self.sequence(), before + 1)
        os.write(self.fd, b"if true; then\r")
        partial = self.read_until(lambda output: b"BASH_MORE> " in output)
        self.assertNotIn(b"\x1b]133;C", partial)
        os.write(self.fd, b"printf multiline; false; fi\r")
        output = self.read_until(lambda output: b"BASH_READY> " in output)
        self.assertNotIn(b"\x1b]133;C", output)
        self.assertNotIn(b"\x1b]133;D", output)

    def test_prompt_array_keeps_entries_and_bash_version_semantics(self):
        rc = "PROMPT_COMMAND=(\"$PROMPT_COMMAND\" 'printf ARRAY_ONE' 'printf ARRAY_TWO')\n"
        self.start_shell(rc=rc, prompt_command="printf OLD")
        output = self.command("declare -p PROMPT_COMMAND")
        self.assertIn(b"declare -a PROMPT_COMMAND=", output)
        self.assertIn(b"printf ARRAY_ONE", output)
        self.assertIn(b"printf ARRAY_TWO", output)
        self.assertIn(b"OLD", output)

    def test_dirty_readiness_and_persistent_input_survive_new_observer(self):
        self.start_shell()
        sequence = self.sequence()
        self.assertEqual(self.probe("clean", sequence, "nil"), "true")
        self.assertEqual(self.probe("clean", sequence, sequence), "false")
        self.assertEqual(self.probe("clean", 1, 0), "false")
        self.assertEqual(self.probe("persistent-input", self.root, self.pid), "true")
        self.assertEqual(self.probe("persistent-clean", self.root, self.pid, sequence), "false")
        self.command("")
        self.assertEqual(self.probe("persistent-clean", self.root, self.pid, self.sequence()), "true")

    def test_readiness_rejects_wrong_pid_symlink_fifo_and_oversize(self):
        self.start_shell()
        ready = self.root / "command-task-ready.pid"
        self.assertEqual(self.probe("ready", self.root, self.pid + 1), "nil")
        for text in ("x" * 1024, f"{self.pid}:0\\n", "0:123\\n"):
            ready.write_text(text)
            self.assertIsNone(self.sequence())
        ready.unlink()
        target = self.root / "target"
        target.write_text(f"{self.pid}:100\n")
        ready.symlink_to(target)
        self.assertIsNone(self.sequence())
        ready.unlink()
        os.mkfifo(ready)
        self.assertIsNone(self.sequence())

    def test_input_queued_during_initialization_is_preserved(self):
        initialized = self.root / "initialized"
        initialization = "sleep .15; printf INITIALIZED > " + shlex.quote(str(initialized))
        original_reader = self.read_until
        def reader(predicate, timeout=5):
            os.write(self.fd, b"printf STARTUP_DRAFT")
            self.read_until = original_reader
            return original_reader(predicate, timeout)
        self.read_until = reader
        startup = self.start_shell(initialization=initialization)
        self.assertEqual(initialized.read_text(), "INITIALIZED")
        self.assertIn(b"printf STARTUP_DRAFT", startup)
        self.assertNotIn(b"\x1b]133;C", startup)
        output = self.command("")
        self.assertIn(b"STARTUP_DRAFT", output)
        self.assertNotIn(b"\x1b]133;D", output)

    def test_manual_pipeline_keeps_pipe_status_and_debug_trap(self):
        self.start_shell()
        output = self.command("false | true; printf 'PIPE_STATUS:%s\\n' \"${PIPESTATUS[*]}\"")
        self.assertIn(b"PIPE_STATUS:1 0", output)
        self.assertNotIn(b"\x1b]133;C", output)
        self.task(["/bin/bash", "-c", "(false)"], 1)

    def test_exact_interactive_argv_variants(self):
        for argv in ([BASH], [BASH, "-l"], [BASH, "-i"], [BASH, "-il"], [BASH, "-li"], [BASH, "-l", "-i"]):
            self.assertEqual(self.probe("argv", *argv), "true")
        for argv in ([], ["bash"], [BASH, "-c", "true"], [BASH, "-s"], [BASH, "script.sh"],
                     [BASH, "--norc"], [BASH, "-lic", "true"], ["/bin/sh", "-i"], [BASH, "--"]):
            self.assertEqual(self.probe("argv", *argv), "false")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bash", default=BASH)
    options, remaining = parser.parse_known_args()
    BASH = str(Path(options.bash).resolve())
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
