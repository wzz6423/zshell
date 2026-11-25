"""Verify one-shot command notifications in real original-shell PTYs.

The fixture compiles production shell integration and private result parsing.
It never reads personal shell files or asks macOS for notification permission.
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


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "mac/zshell"


class NextCommandNotificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-next-command-build-", dir="/tmp")
        cls.addClassCleanup(cls.build.cleanup)
        temporary = Path(cls.build.name)
        connections = (SOURCE / "PersistentCLIConnection.swift").read_text()
        private_io = connections[connections.index("    static func preparePrivateDirectory"):connections.rindex("}")]
        wire = (SOURCE / "PTYMux.swift").read_text()
        write_all = wire[wire.index("    static func writeAll"):wire.index("    private static func readExactly")]
        support = temporary / "Support.swift"
        support.write_text("import Darwin\nimport Foundation\n"
                           "enum CLIError: Error { case message(String) }\n"
                           "enum PTYMuxConstants { static let maximumFrameBytes = 256 * 1024 }\n"
                           "enum PTYMuxWire { static func errnoError(_ value: String) -> CLIError { .message(value) }\n"
                           + write_all + "}\nenum PersistentCLIConnection {\n" + private_io + "}\n")
        probe = temporary / "Probe.swift"
        probe.write_text(r'''
import Foundation
@main struct Probe {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "generate" {
            let script = "autoload -Uz add-zsh-hook\n" + TerminalCommandNotificationShellIntegration.script(
                in: directory, finishSeconds: Int(CommandLine.arguments[3])!, onError: CommandLine.arguments[4] == "true")
            try script.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return
        }
        let pid = pid_t(CommandLine.arguments[3])!
        guard let integrationID = TerminalNextCommandNotificationRequest.integrationID(in: directory, shellPID: pid) else {
            print("null"); return
        }
        if mode == "ready" { print(integrationID); return }
        let request = TerminalNextCommandNotificationRequest(
            id: UUID(uuidString: CommandLine.arguments[4])!, shellPID: pid, integrationID: integrationID)
        if mode == "arm" { try request.arm(in: directory); return }
        if let result = request.result(in: directory) {
            print(String(decoding: try JSONSerialization.data(withJSONObject: [
                "integration_id": result.command.id.uuidString,
                "sequence": result.command.sequence, "exit_code": result.command.exitCode, "message": result.message,
            ]), as: UTF8.self))
        } else { print("null") }
    }
}
''')
        cls.probe = temporary / "probe"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(support), str(probe),
                        str(SOURCE / "TerminalCommandNotificationResult.swift"),
                        str(SOURCE / "TerminalNextCommandNotification.swift"), "-o", str(cls.probe)], check=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zshell-next-command-'", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        subprocess.run([str(self.probe), "generate", str(self.directory), "0", "false"], check=True)
        user = self.directory / "user"
        user.mkdir()
        prompt = "\nPROMPT='NEXT-COMMAND> '; RPROMPT=''; bindkey -e\n"
        (user / ".zshrc").write_text(prompt)
        config = self.directory / ".zshrc"
        config.write_text(f"export ZDOTDIR={shlex.quote(str(user))}\n" + config.read_text() + prompt)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(ZDOTDIR=str(self.directory), TERM="xterm-256color")
            os.execv("/bin/zsh", ["zsh", "-di"])
        self.addCleanup(self.close_shell)
        self.prompt()

    def close_shell(self):
        os.close(self.fd)
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)

    def read_until(self, predicate):
        data = b""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], .03)[0]:
                data += os.read(self.fd, 65536)
                if predicate(data):
                    return data
        self.fail(f"PTY did not reach expected state: {data!r}")

    def prompt(self):
        return self.read_until(lambda data: b"NEXT-COMMAND> " in data)

    def send(self, command):
        os.write(self.fd, command.encode() + b"\r")

    def command(self, command):
        self.send(command)
        return self.prompt()

    def arm(self, pid=None):
        token = str(uuid.uuid4()).upper()
        subprocess.run([str(self.probe), "arm", str(self.directory), str(pid or self.pid), token], check=True)
        self.assertEqual((self.directory / "next-command-notification.request").stat().st_mode & 0o777, 0o600)
        return token

    def result(self, token, pid=None):
        return json.loads(subprocess.check_output([str(self.probe), "read", str(self.directory),
                                                  str(pid or self.pid), token], text=True, timeout=2))

    def test_next_short_command_is_one_shot_and_survives_rapid_commands(self):
        token = self.arm()
        self.command("true")
        first = self.result(token)
        self.assertEqual(first["exit_code"], 0)
        self.assertTrue(first["message"].startswith("true finished"))
        self.command("false")
        self.command("true")
        self.assertEqual(self.result(token), first)

    def test_arm_while_busy_skips_the_running_command(self):
        self.send("printf 'CURRENT-COMMAND-RUNNING\\n'; read -r answer")
        self.read_until(lambda data: b"CURRENT-COMMAND-RUNNING\r\n" in data)
        token = self.arm()
        os.write(self.fd, b"done\r")
        self.prompt()
        self.assertIsNone(self.result(token))
        self.command("false")
        self.assertEqual(self.result(token)["exit_code"], 1)

    def test_cancel_before_start_and_during_execution(self):
        token = self.arm()
        request = self.directory / "next-command-notification.request"
        request.unlink()
        self.command("true")
        self.assertIsNone(self.result(token))
        token = self.arm()
        self.send("printf 'ARMED-COMMAND-RUNNING\\n'; read -r answer")
        self.read_until(lambda data: b"ARMED-COMMAND-RUNNING\r\n" in data)
        request.unlink()
        os.write(self.fd, b"done\r")
        self.prompt()
        self.assertIsNone(self.result(token))

    def test_rearm_during_execution_only_consumes_the_next_command(self):
        first = self.arm()
        self.send("printf 'REARM-COMMAND-RUNNING\\n'; read -r answer")
        self.read_until(lambda data: b"REARM-COMMAND-RUNNING\r\n" in data)
        second = self.arm()
        os.write(self.fd, b"done\r")
        self.prompt()
        self.assertIsNone(self.result(first))
        self.assertIsNone(self.result(second))
        self.command("false")
        self.assertEqual(self.result(second)["exit_code"], 1)

    def test_nested_shell_completion_does_not_consume_root_notification(self):
        self.command("zsh -di")
        token = self.arm()
        self.command("false")
        self.assertIsNone(self.result(token))
        self.command("exit")
        self.assertIsNone(self.result(token))
        self.command("true")
        self.assertEqual(self.result(token)["exit_code"], 0)

    def test_exec_replacement_retires_readiness(self):
        token = self.arm()
        self.command("exec zsh -di")
        ready = subprocess.check_output([str(self.probe), "ready", str(self.directory), str(self.pid)], text=True)
        self.assertEqual(ready.strip(), "null")
        self.assertIsNone(self.result(token))

    def test_nonzero_status_is_captured_before_prompt_hooks(self):
        self.command("_fixture_prompt() { true; }; precmd_functions+=(_fixture_prompt)")
        token = self.arm()
        self.command("(exit 7)")
        self.assertEqual(self.result(token)["exit_code"], 7)

    def test_wrong_identity_oversized_symlink_and_fifo_results_fail_boundedly(self):
        token = self.arm()
        self.command("true")
        self.assertIsNone(self.result(token, pid=self.pid + 1))
        result = self.directory / "next-command-notification.result"
        original = result.read_text()
        for invalid in (original.replace(token, str(uuid.uuid4())), "x" * 1024):
            result.write_text(invalid)
            self.assertIsNone(self.result(token))
        result.unlink()
        target = self.directory / "other"
        target.write_text(original)
        target.chmod(0o600)
        result.symlink_to(target)
        self.assertIsNone(self.result(token))
        result.unlink()
        os.mkfifo(result, mode=0o600)
        self.assertIsNone(self.result(token))


if __name__ == "__main__":
    unittest.main(verbosity=2)
