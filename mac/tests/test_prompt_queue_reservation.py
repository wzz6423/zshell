"""Check production queue reservations against delayed, real zsh/ZLE input.

Run: python3 -B mac/tests/test_prompt_queue_reservation.py
The renderer is absent so shell acknowledgements must also work for parked panes.
"""
import base64
import os
from pathlib import Path
import select
import shlex
import subprocess
import tempfile
import time
import unittest

from test_prompt_selection import PromptSelectionTests, SOURCE


class PromptQueueReservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        PromptSelectionTests.setUpClass()
        cls.addClassCleanup(PromptSelectionTests.doClassCleanups)
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-queue-reservation-")
        cls.addClassCleanup(cls.build.cleanup)
        session = SOURCE.read_text()
        cls.submit = b"\x1b[27;9;13~" if "_zshell_prompt_queue_submit()" in session else b"\r"
        queue = (SOURCE.parent / "TerminalPromptQueue.swift").read_text()
        storage = session[session.index("    var promptQueueDispatchGeneration:"):
                          session.index("    init(", session.index("    var promptQueueDispatchGeneration:"))]
        reservation = session[session.index("    /// Reserve"):
                              session.index("    func sendEnter()", session.index("    /// Reserve"))]
        readiness = session[session.index("    var terminalPromptSelectionIsReady:"):
                            session.index("    func terminalDidChangeTitle(")]
        gate = queue[queue.index("    var canSendQueuedPrompt:"):queue.index("    /// Explicit sends")]
        reserve_call = ("session.reservePromptQueueSend(for: command)" if "reservePromptQueueSend(for " in reservation
                        else "session.reservePromptQueueSend()")
        helper = Path(cls.build.name) / "main.swift"
        helper.write_text(
            "import Foundation\n"
            "struct AppSettings { static let shared = AppSettings(); let promptQueueEnabled = true }\n"
            "struct Queue { let isEnabled = true }\n"
            "struct Surface { let foregroundPid: pid_t? }\n"
            "struct TerminalCommandTaskStore { static let shared = TerminalCommandTaskStore(); "
            "func hasActiveTask(terminalID: UUID) -> Bool { false } }\n"
            "final class Session {\nlet id = UUID()\nlet promptQueue = Queue()\n"
            "let hasExited = false\nlet isTerminating = false\nlet shellPid: pid_t?\n"
            "let launchDirectoryURL: URL?\nlet surface: Surface\n"
            + storage + reservation + readiness + gate +
            "init(directory: URL, pid: pid_t) { launchDirectoryURL = directory; shellPid = pid; "
            "surface = Surface(foregroundPid: pid) }\n}\n"
            "let session = Session(directory: URL(fileURLWithPath: CommandLine.arguments[1]), "
            "pid: pid_t(CommandLine.arguments[2])!)\n"
            "while let line = readLine() {\n"
            "if line.hasPrefix(\"reserve \") {\n"
            "let command = String(data: Data(base64Encoded: String(line.dropFirst(8)))!, encoding: .utf8)!\n"
            f"print({reserve_call})\n"
            "} else { print(session.canSendQueuedPrompt) }\nfflush(stdout)\n}\n"
        )
        cls.helper = Path(cls.build.name) / "reservation"
        subprocess.run(["swiftc", str(helper), "-o", str(cls.helper)], check=True)

    def setUp(self):
        self.shell = PromptSelectionTests()
        self.addCleanup(self.shell.doCleanups)
        self.shell.setUp(
            "autoload -Uz add-zle-hook-widget\n"
            "_queue_user_line_finish() {\n"
            'if [[ -f "$ZDOTDIR/queue-failing-hook" ]]; then\n'
            'builtin print -rn -- "$BUFFER" >| "$ZDOTDIR/queue-hook-buffer"\n'
            "return 1\nfi\nreturn 0\n}\n"
            "add-zle-hook-widget line-finish _queue_user_line_finish\n"
        )
        self.driver = subprocess.Popen(
            [str(self.helper), str(self.shell.launch), str(self.shell.pid)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.close_driver)

    def close_driver(self):
        self.driver.stdin.close()
        self.driver.wait(timeout=3)
        self.driver.stdout.close()

    def ask(self, message="ready"):
        self.driver.stdin.write(message + "\n")
        self.driver.stdin.flush()
        return self.driver.stdout.readline().strip() == "true"

    def reserve(self, command):
        return self.ask("reserve " + base64.b64encode(command.encode()).decode())

    def send(self, command):
        self.assertTrue(self.reserve(command))
        os.write(self.shell.fd, command.encode() + self.submit)
        return self.shell.wait_prompt()

    def wait_file(self, path):
        deadline = time.monotonic() + 4
        while not path.exists() and time.monotonic() < deadline:
            if select.select([self.shell.fd], [], [], 0)[0]:
                os.read(self.shell.fd, 65536)
            time.sleep(.01)
        self.assertTrue(path.exists(), f"Shell did not write {path.name}")

    def test_keymap_redraw_cannot_release_buffered_command(self):
        shell = self.shell
        armed = shell.root / "armed"
        paused = shell.root / "paused"
        release = shell.root / "release"
        started = shell.root / "started"
        swallowed = shell.root / "swallowed"
        second = shell.root / "second"
        q = lambda path: shlex.quote(str(path))
        shell.command(
            "_queue_change_keymap() { zle -K viins; }; "
            "zle -N _queue_change_keymap; bindkey '^X' _queue_change_keymap; "
            "_queue_hold_redraw() { "
            f"if [[ -f {q(armed)} ]]; then /bin/rm -f -- {q(armed)}; "
            f"builtin print paused >| {q(paused)}; "
            f"while [[ ! -f {q(release)} ]]; do /bin/sleep .01; done; fi; }}; "
            "add-zle-hook-widget line-pre-redraw _queue_hold_redraw"
        )
        first_command = (f"builtin print started >| {q(started)}; read -r answer; "
                         f"builtin print -rn -- \"$answer\" >| {q(swallowed)}")
        second_command = f"printf second > {q(second)}"
        armed.touch()
        self.assertTrue(self.reserve(first_command))
        os.write(shell.fd, b"\x18" + first_command.encode() + self.submit)
        try:
            self.wait_file(paused)
            self.assertFalse(started.exists(), "First command must still be buffered in the PTY")
            ready_after_redraw = self.ask()
            second_accepted = self.reserve(second_command)
            if second_accepted:
                os.write(shell.fd, second_command.encode() + self.submit)
        finally:
            release.touch()
        self.wait_file(started)
        if not second_accepted:
            self.assertFalse(self.ask(), "Builtin read still owns the shell input")
            os.write(shell.fd, b"deliberate answer\r")
            shell.wait_prompt()
        self.wait_file(swallowed)
        shell.drain()
        print(f"redraw readiness={ready_after_redraw}, second accepted={second_accepted}, "
              f"foreground read={swallowed.read_text()!r}", flush=True)
        self.assertFalse(ready_after_redraw, "A keymap redraw is not an acknowledgement of the submitted command")
        self.assertFalse(second_accepted, "Second send must wait for the first command's completed empty prompt")
        self.assertEqual(swallowed.read_text(), "deliberate answer")
        self.assertFalse(second.exists())
        self.assertTrue(self.ask())
        self.send(second_command)
        self.assertEqual(second.read_text(), "second")

    def test_fast_commands_complete_without_renderer_events(self):
        marker = self.shell.root / "fast"
        for command in (":", "printf fast > " + shlex.quote(str(marker)), "false", "true", ":"):
            with self.subTest(command=command):
                self.send(command)
                self.assertTrue(self.ask(), "Completed empty prompt must release a parked reservation")
        self.assertEqual(marker.read_text(), "fast")

    def test_earlier_failing_user_hook_cannot_skip_acknowledgement(self):
        (self.shell.original / "queue-failing-hook").touch()
        marker = self.shell.root / "after-failing-hook"
        command = "builtin print -rn -- first >| " + shlex.quote(str(marker))
        self.send(command)
        self.assertEqual(marker.read_text(), "first")
        self.assertEqual((self.shell.original / "queue-hook-buffer").read_text(), command)
        self.assertTrue(self.ask(), "A failing user hook must not hide the accepted command's completion")
        self.send("builtin print -rn -- second >> " + shlex.quote(str(marker)))
        self.assertEqual(marker.read_text(), "firstsecond")
        self.assertTrue(self.ask())
        os.write(self.shell.fd, b"read -r answer\r")
        self.shell.drain()
        self.assertFalse(self.ask(), "A failing hook must still revoke readiness for ordinary builtin input")
        self.assertFalse(self.shell.ready())
        os.write(self.shell.fd, b"deliberate answer\r")
        self.shell.wait_prompt()
        self.assertTrue(self.ask())

    def test_later_user_hook_must_finish_before_accepted_buffer_check(self):
        marker = self.shell.root / "rewritten-command"
        original = self.shell.root / "original-command"
        replacement = "builtin print -rn -- rewritten >| " + shlex.quote(str(marker))
        self.shell.command(
            "_queue_rewrite_line() { "
            f'if [[ -f "$ZDOTDIR/queue-rewrite-hook" ]]; then BUFFER={shlex.quote(replacement)}; fi; '
            "return 0; }; add-zle-hook-widget line-finish _queue_rewrite_line"
        )
        (self.shell.original / "queue-rewrite-hook").touch()
        command = "builtin print -rn -- original >| " + shlex.quote(str(original))
        self.send(command)
        self.assertEqual(marker.read_text(), "rewritten")
        self.assertFalse(original.exists())
        self.assertFalse(self.ask(), "A hook-rewritten line must not acknowledge the original queue request")
        (self.shell.original / "queue-rewrite-hook").unlink()
        os.write(self.shell.fd, command.encode() + self.submit)
        self.shell.wait_prompt()
        self.assertEqual(original.read_text(), "original")
        self.assertTrue(self.ask())

    def test_original_shell_builtin_read_requires_completion(self):
        command = "read -r answer"
        self.assertTrue(self.reserve(command))
        os.write(self.shell.fd, command.encode() + self.submit)
        self.shell.drain()
        self.assertFalse(self.ask())
        self.assertFalse(self.reserve(":"))
        os.write(self.shell.fd, b"answer\r")
        self.shell.wait_prompt()
        self.assertTrue(self.ask())

    def test_ordinary_return_does_not_acknowledge_the_same_text(self):
        command = ":"
        self.assertTrue(self.reserve(command))
        self.shell.command(command)
        self.assertFalse(self.ask(), "Matching text submitted with ordinary Return is not this queue send")
        os.write(self.shell.fd, command.encode() + self.submit)
        self.shell.wait_prompt()
        self.assertTrue(self.ask())

    def test_mismatched_line_and_unrelated_prompt_cannot_acknowledge(self):
        command = "printf exact"
        self.assertTrue(self.reserve(command))
        os.write(self.shell.fd, b":" + self.submit)
        self.shell.wait_prompt()
        self.assertFalse(self.ask(), "Private submit key alone must not acknowledge another command")
        self.shell.command(":")
        self.assertFalse(self.ask())
        os.write(self.shell.fd, command.encode() + self.submit)
        self.shell.wait_prompt()
        self.assertTrue(self.ask())

    def test_completed_ack_recovers_after_deleted_state_files(self):
        self.send(":")
        completed = self.shell.launch / "prompt-queue.completed"
        self.assertTrue(completed.exists())
        completed.unlink()
        self.shell.queue_state_file.unlink()
        os.write(self.shell.fd, b"\x0c")
        self.shell.drain()
        self.assertTrue(self.ask())

    def test_completed_command_retains_reservation_while_draft_is_present(self):
        self.send(":")
        self.assertEqual(self.shell.buffer(b"unsent draft"), "unsent draft")
        self.assertFalse(self.ask())
        self.assertFalse(self.reserve("printf leaked"))
        self.assertEqual(self.shell.buffer(b"\x15"), "")
        self.assertTrue(self.ask())

    def test_unicode_and_quoted_commands_match_exactly(self):
        marker = self.shell.root / "Unicode 你好 العربية.txt"
        self.send("builtin print -rn -- '你好 العربية café 👩🏽‍💻' >| " + shlex.quote(str(marker)))
        self.assertEqual(marker.read_text(), "你好 العربية café 👩🏽‍💻")
        self.assertTrue(self.ask())

    def test_parse_error_and_comment_return_to_empty_prompt(self):
        self.shell.command("setopt INTERACTIVE_COMMENTS")
        for command in ("# comment only", "echo )", "# comment only"):
            with self.subTest(command=command):
                self.send(command)
                self.assertTrue(self.ask())


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(PromptQueueReservationTests(name)
                              for name in vars(PromptQueueReservationTests) if name.startswith("test_"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
