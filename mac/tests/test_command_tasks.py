"""Run command-task integration in real zsh PTYs and validate retained results.

Run: python3 mac/tests/test_command_tasks.py
Uses only the standard library, swiftc, and /bin/zsh; all artifacts are temporary.
"""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
import uuid

import test_prompt_selection

SOURCE = Path(__file__).resolve().parents[1] / "zshell"


class CommandTaskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        test_prompt_selection.PromptSelectionTests.setUpClass()
        cls.addClassCleanup(test_prompt_selection.PromptSelectionTests.doClassCleanups)
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-command-test-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        helper = Path(cls.build.name) / "main.swift"
        helper.write_text(r'''
import Foundation
if CommandLine.arguments[1] == "validate" {
    print(TerminalCommandTaskShellIntegration.replacesOriginalShell(Array(CommandLine.arguments.dropFirst(2))))
    exit(0)
}
let id = UUID(uuidString: CommandLine.arguments[1])!
let pid = pid_t(CommandLine.arguments[2])!
let directory = URL(fileURLWithPath: CommandLine.arguments[3])
if let result = TerminalCommandTaskShellResult.read(taskID: id, shellPID: pid, directory: directory) {
    var task = TerminalCommandTask(projectID: UUID(), paneID: UUID(), terminalID: UUID(), argv: ["false"])
    task.start()
    precondition(!task.observeCompletion(sequence: 1, shellResult: result, output: { "wrong" }))
    var matching = TerminalCommandTask(id: id, projectID: UUID(), paneID: UUID(), terminalID: UUID(), argv: ["false"])
    matching.start()
    precondition(matching.observeCompletion(sequence: 0, shellResult: result, output: {
        "final-output " + String(repeating: "中", count: 50000)
    }))
    let saved = matching.json
    precondition(!matching.observeCompletion(sequence: 2, shellResult: result, output: { "overwritten" }))
    precondition(saved == matching.json)
    precondition(matching.output!.utf8.count <= TerminalCommandTask.outputLimitBytes)
    precondition(!matching.output!.contains("\u{fffd}"))
    let data = try JSONEncoder().encode(saved)
    print(String(decoding: data, as: UTF8.self))
} else { print("null") }
''')
        cls.reader = Path(cls.build.name) / "reader"
        subprocess.run([
            "swiftc", str(helper), str(SOURCE / "ZshellAutomationProtocol.swift"),
            str(SOURCE / "TerminalCommandTask.swift"),
            str(SOURCE / "TerminalCommandTaskShellIntegration.swift"),
            "-o", str(cls.reader),
        ], check=True)
        wait_source = Path(cls.build.name) / "wait.swift"
        wait_source.write_text(r'''
import Foundation
enum CLIError: Error { case message(String) }
final class AppConnection {
    var completed = false
    var closed = false
    func automationRequest(method: String, params: [String: ZshellJSONValue], timeout: TimeInterval) throws -> ZshellJSONValue {
        precondition(method == "pane.task" && params["wait"] == .bool(true))
        precondition(params["task_id"] == .string("task-id"))
        return .object(["task": .object([
            "state": .string(closed ? "closed" : completed ? "completed" : "running"),
            "exit_code": completed ? .number(7) : .null,
            "duration_ms": completed ? .number(42) : .null,
            "output": completed ? .string("final-output") : .null,
        ])])
    }
}
@main struct WaitProbe {
    static func main() throws {
        let connection = AppConnection()
        let timeout = try TerminalCommandTaskWait.wait(taskID: "task-id", timeoutMS: 100, connection: connection)
        precondition(TerminalCommandTaskWait.exitCode(for: timeout) == 124)
        precondition(timeout.objectValue?["timed_out"] == .bool(true))
        connection.completed = true
        let result = try TerminalCommandTaskWait.wait(taskID: "task-id", timeoutMS: 100, connection: connection)
        precondition(TerminalCommandTaskWait.exitCode(for: result) == 7)
        let repeated = try TerminalCommandTaskWait.wait(taskID: "task-id", timeoutMS: 100, connection: connection)
        precondition(result == repeated)
        connection.completed = false
        connection.closed = true
        let closed = try TerminalCommandTaskWait.wait(taskID: "task-id", timeoutMS: 100, connection: connection)
        precondition(TerminalCommandTaskWait.exitCode(for: closed) == 1)
        print("timeout=124 repeat=7 closed=1 stable=true")
    }
}
''')
        cls.wait_reader = Path(cls.build.name) / "wait-reader"
        subprocess.run([
            "swiftc", str(wait_source), str(SOURCE / "ZshellAutomationProtocol.swift"),
            str(SOURCE / "TerminalCommandTaskWait.swift"), "-o", str(cls.wait_reader),
        ], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zshell-command-'", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.user = self.root / "user"
        self.user.mkdir()
        (self.user / ".zshrc").write_text(
            "PROMPT='TASK-READY> '; RPROMPT=''; bindkey -e\n"
            "_test_prompt_work() { true; }; precmd_functions=(_test_prompt_work)\n"
        )
        integration = subprocess.check_output([
            str(test_prompt_selection.PromptSelectionTests.helper), "generate", str(self.root),
        ], text=True).strip()
        (self.root / "command-tasks").mkdir()
        self.integration = integration
        self.fd = None
        self.pid = None
        self.addCleanup(self.close_shell)

    def start_shell(self, backend):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(
                ZDOTDIR=self.integration, ZSHELL_ORIGINAL_ZDOTDIR=str(self.user),
                ZSHELL_TERM=backend, TERM="xterm-256color", LC_ALL="en_US.UTF-8",
            )
            os.execv("/bin/zsh", ["zsh", "-dil"])
        self.read_until(lambda data: b"TASK-READY> " in data)
        self.assertEqual((self.root / "command-task-ready.pid").read_text().strip(), str(self.pid))

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
                # Drain the prompt's line-init work before sending another line.
                while select.select([self.fd], [], [], .05)[0]:
                    output += os.read(self.fd, 65536)
                return output
        self.fail(f"PTY condition timed out: {output!r}")

    def run_task(self, argv, status):
        task = str(uuid.uuid4()).upper()
        command = shlex.join(["_zshell_command_task", task] + argv)
        os.write(self.fd, command.encode() + b"\r")
        output = self.read_until(lambda data: b"TASK-READY> " in data)
        self.assertIn(b"\x1b]133;C;cmdline_url=", output)
        self.assertIn(f"\x1b]133;D;{status}\x07".encode(), output)
        snapshot = json.loads(subprocess.check_output([
            str(self.reader), task, str(self.pid), str(self.root / "command-tasks"),
        ], text=True))
        self.assertEqual(snapshot["task_id"], task)
        self.assertEqual(snapshot["state"], "completed")
        self.assertEqual(snapshot["exit_code"], status)
        self.assertGreaterEqual(snapshot["duration_ms"], 0)
        self.assertFalse(snapshot["output_complete"])
        return task, output

    def test_failures_success_quoting_and_job_status_in_both_backends(self):
        for backend in ("alacritty", "ghostty"):
            with self.subTest(backend=backend):
                self.start_shell(backend)
                first, _ = self.run_task(["/bin/sh", "-c", "printf failed-output; exit 7"], 7)
                second, _ = self.run_task(["/usr/bin/true"], 0)
                self.assertNotEqual(first, second)
                _, output = self.run_task([
                    "/bin/sh", "-c", "printf '<%s>|<%s>|<%s>' \"$1\" \"$2\" \"$3\"", "sh",
                    "single'quote", 'double"quote', "$(printf INJECTED); `false` 中文",
                ], 0)
                self.assertIn(b"<single'quote>|<double\"quote>|<$(printf INJECTED); `false`", output)
                self.run_task(["/bin/sh", "-c", "(sleep .15; exit 0) & exit 7"], 7)
                self.run_task(["/usr/bin/env", "zshell-missing-executable-test"], 127)
                self.close_shell()

    def test_direct_shell_replacement_is_rejected(self):
        for argv in (["exit", "7"], ["logout"], ["exec", "/bin/sleep", "30"],
                     ["builtin", "exit", "7"], ["builtin", "exec", "/bin/sh"]):
            self.assertEqual(subprocess.check_output([str(self.reader), "validate", *argv], text=True).strip(), "true")
        for argv in (["/bin/sh", "-c", "exit 7"], ["printf", "exit"], ["/usr/bin/true"]):
            self.assertEqual(subprocess.check_output([str(self.reader), "validate", *argv], text=True).strip(), "false")

    def test_early_shell_exit_does_not_publish_success(self):
        self.start_shell("ghostty")
        task = str(uuid.uuid4()).upper()
        # Noninteractive zsh exits without its interactive "stopped jobs" guard.
        script = 'source ' + shlex.quote(str(Path(self.integration) / '.zshrc')) + '; ' + shlex.join(["_zshell_command_task", task, "exit", "7"])
        env = os.environ.copy()
        env.update(ZSHELL_ORIGINAL_ZDOTDIR=str(self.user), ZSHELL_TERM="ghostty")
        result = subprocess.run(["/bin/zsh", "-dfc", script], env=env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 7)
        self.assertFalse((self.root / "command-tasks" / (task + ".result")).exists())

    def test_interrupt_records_the_command_status(self):
        self.start_shell("alacritty")
        task = str(uuid.uuid4()).upper()
        os.write(self.fd, shlex.join(["_zshell_command_task", task, "/bin/sleep", "10"]).encode() + b"\r")
        self.read_until(lambda data: b"\x1b]133;C;cmdline_url=" in data)
        os.write(self.fd, b"\x03")
        output = self.read_until(lambda data: b"TASK-READY> " in data)
        self.assertIn(b"\x1b]133;D;130\x07", output)
        result = json.loads(subprocess.check_output([
            str(self.reader), task, str(self.pid), str(self.root / "command-tasks"),
        ], text=True))
        self.assertEqual(result["exit_code"], 130)

    def test_timeout_can_be_waited_again_and_closed_tasks_fail(self):
        self.assertEqual(subprocess.check_output([str(self.wait_reader)], text=True).strip(),
                         "timeout=124 repeat=7 closed=1 stable=true")

    def test_result_rejects_another_shell_invalid_status_and_oversize(self):
        self.start_shell("ghostty")
        task, _ = self.run_task(["/usr/bin/true"], 0)
        directory = self.root / "command-tasks"
        args = [str(self.reader), task, str(self.pid), str(directory)]
        self.assertEqual(subprocess.check_output(args[:2] + [str(self.pid + 1)] + args[3:], text=True).strip(), "null")
        result_file = directory / (task + ".result")
        for value in (f"1\t{task}\t{self.pid}\t256\t0\n", "x" * 1024,
                      f"1\t{uuid.uuid4()}\t{self.pid}\t0\t0\n"):
            result_file.write_text(value)
            self.assertEqual(subprocess.check_output(args, text=True).strip(), "null")


if __name__ == "__main__":
    unittest.main(verbosity=2)
