"""Exercise the app's generated integration and readiness check against macOS ZLE.

Run: python3 mac/tests/test_prompt_selection.py
Only the standard library, swiftc, and /bin/zsh are required.
"""
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "zshell/TerminalSession.swift"
CLICK = b"\x1f\x1b[27;2;27~"


class PromptSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="zshell-selection-test-")
        cls.addClassCleanup(cls.build.cleanup)
        source = SOURCE.read_text()
        generator = source[source.index("    private static func makeShellIntegrationArtifacts("):
                           source.index("    private static func validWorkingDirectory(")]
        readiness = source[source.index("    var terminalPromptSelectionIsReady: Bool {"):
                           source.index("    func terminalDidChangeTitle(")]
        helper = Path(cls.build.name) / "main.swift"
        helper.write_text("import Foundation\n"
                          # #76 bakes the notification settings into the shim
                          # text; stub them off so the generated script stays
                          # byte-identical to the pre-#76 baseline.
                          "struct AppSettings {\n"
                          "static var shared = AppSettings()\n"
                          "var notifyFinishSeconds = 0\n"
                          "var notifyOnError = false\n"
                          "var shellCompletions = false\n}\n"
                          "struct Surface { var foregroundPid: pid_t? }\n"
                          "struct Session {\nvar hasExited = false\n"
                          "var launchDirectoryURL: URL?\nvar surface: Surface\n"
                          + generator.replace("private static func", "static func")
                          + readiness + "\n}\n"
                          'let directory = URL(fileURLWithPath: CommandLine.arguments[2])\n'
                          'if CommandLine.arguments[1].hasPrefix("generate") {\n'
                          'AppSettings.shared.shellCompletions = CommandLine.arguments[1] == "generate-completions"\n'
                          'print(try Session.makeShellIntegrationArtifacts(in: directory, shellPath: "/bin/zsh")!.path)\n'
                          '} else if CommandLine.arguments[1] == "queue" {\n'
                          'print(Session(launchDirectoryURL: directory, surface: Surface(foregroundPid: pid_t(CommandLine.arguments[3]))).terminalPromptQueueIsReady)\n'
                          '} else {\n'
                          'print(Session(launchDirectoryURL: directory, surface: Surface(foregroundPid: pid_t(CommandLine.arguments[3]))).terminalPromptSelectionIsReady)\n}\n')
        cls.helper = Path(cls.build.name) / "integration"
        shutil.copytree(SOURCE.parent / "ShellIntegration", Path(cls.build.name) / "ShellIntegration")
        subprocess.run(["swiftc", str(helper),
                        str(SOURCE.parent / "TerminalCommandTaskShellIntegration.swift"),
                        str(SOURCE.parent / "TerminalShellCompletions.swift"),
                        "-o", str(cls.helper)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zshell-prompt-'")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.launch = self.root / "launch"
        self.launch.mkdir(mode=0o700)
        self.original = self.root / "user"
        self.original.mkdir()
        self.buffer_file = self.root / "buffer"
        self.state_file = self.launch / "prompt-selection.pid"
        self.queue_state_file = self.launch / "prompt-queue.pid"
        self.config = (
            "bindkey -e\nPROMPT='READY> '\nRPROMPT=''\n"
            "bindkey '^[[3~' delete-char\n"
            f"_dump() {{ print -rn -- \"$BUFFER\" >| {shlex.quote(str(self.buffer_file))}; }}\n"
            "zle -N _dump\n"
            "for map in emacs viins vicmd; do bindkey -M $map '^T' _dump; done\n"
            "_test_select_left() { (( REGION_ACTIVE )) || zle set-mark-command; zle backward-char; }\n"
            "_test_select_right() { (( REGION_ACTIVE )) || zle set-mark-command; zle forward-char; }\n"
            "zle -N _test_select_left\nzle -N _test_select_right\n"
            "bindkey '^[[1;2D' _test_select_left\nbindkey '^[[1;2C' _test_select_right\n"
            "_test_cancel_region() { REGION_ACTIVE=0; }\n"
            "zle -N _test_cancel_region\nbindkey '^O' _test_cancel_region\n"
        )
        (self.original / ".zshrc").write_text(self.config)
        integration = subprocess.check_output(
            [str(self.helper), "generate", str(self.launch)], text=True).strip()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(ZDOTDIR=integration, ZSHELL_ORIGINAL_ZDOTDIR=str(self.original),
                              TERM="xterm-256color", LC_ALL="en_US.UTF-8")
            os.execv("/bin/zsh", ["zsh", "-dil"])
        self.addCleanup(self.close_shell)
        self.wait_prompt()
        self.assertTrue(self.ready())

    def close_shell(self):
        # Closing the controlling PTY also hangs up any nested foreground shell.
        os.close(self.fd)
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)

    def wait_prompt(self):
        output = b""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], .05)[0]:
                output += os.read(self.fd, 65536)
                if b"READY> " in output:
                    # Let ZLE's line-init finish after the visible prompt.
                    return output + self.drain()
        self.fail(f"No prompt: {output!r}")

    def drain(self):
        output = b""
        while select.select([self.fd], [], [], .05)[0]:
            output += os.read(self.fd, 65536)
        return output

    def command(self, command):
        os.write(self.fd, command.encode() + b"\r")
        return self.wait_prompt()

    def ready(self, pid=None):
        return subprocess.check_output(
            [str(self.helper), "ready", str(self.launch), str(pid or self.pid)],
            text=True).strip() == "true"

    def queue_ready(self):
        return subprocess.check_output(
            [str(self.helper), "queue", str(self.launch), str(self.pid)],
            text=True).strip() == "true"

    def buffer(self, keys):
        self.buffer_file.unlink(missing_ok=True)
        os.write(self.fd, keys + b"\x14")
        deadline = time.monotonic() + 3
        while not self.buffer_file.exists() and time.monotonic() < deadline:
            self.drain()
        self.assertTrue(self.buffer_file.exists(), "ZLE dump widget did not run")
        self.drain()
        return self.buffer_file.read_text()

    def test_repeated_click_preserves_text(self):
        self.assertEqual(self.buffer("abc中文".encode() + CLICK * 10), "abc中文")

    def test_prompt_queue_does_not_append_to_a_draft(self):
        self.assertTrue(self.queue_ready())
        self.assertEqual(self.buffer(b"echo unfinished-draft"), "echo unfinished-draft")
        self.assertTrue(self.ready())
        self.assertFalse(self.queue_ready())
        self.assertEqual(self.buffer(b"\x15"), "")
        self.assertTrue(self.queue_ready())

    def test_prompt_queue_rejects_a_foreground_command(self):
        os.write(self.fd, b"read -r answer\r")
        self.drain()
        self.assertFalse(self.queue_ready())
        os.write(self.fd, b"answer\r")
        self.wait_prompt()
        self.assertTrue(self.queue_ready())

    def test_deleted_launch_directory_recovers_on_command(self):
        self.command("umask 022")
        shutil.rmtree(self.launch)
        self.assertFalse(self.ready())
        output = self.command("umask")
        self.assertNotIn(b"no such file or directory", output)
        self.assertIn(b"022", output)
        self.assertTrue(self.ready())
        self.assertTrue(self.queue_ready())
        self.assertEqual(self.launch.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.buffer(b"abcd\x1f\x1b[D\x1b[D\x1eX"), "abX")

    def test_deleted_launch_directory_recovers_while_editing_a_draft(self):
        self.assertEqual(self.buffer(b"abcd"), "abcd")
        shutil.rmtree(self.launch)
        os.write(self.fd, b"e\x14")
        output = self.drain()
        self.assertNotIn(b"no such file or directory", output)
        self.assertEqual(self.buffer_file.read_text(), "abcde")
        self.assertTrue(self.ready())
        self.assertFalse(self.queue_ready())
        self.assertEqual(self.buffer(b"\x15"), "")
        self.assertTrue(self.queue_ready())

    def test_deleted_readiness_files_recover_on_redraw(self):
        for files in ((self.state_file,), (self.queue_state_file,),
                      (self.state_file, self.queue_state_file)):
            with self.subTest(files=[file.name for file in files]):
                for file in files:
                    file.unlink()
                os.write(self.fd, b"\x0c")
                output = self.drain()
                self.assertNotIn(b"no such file or directory", output)
                self.assertTrue(self.ready())
                self.assertTrue(self.queue_ready())

    def test_deleted_readiness_files_preserve_a_draft_on_redraw(self):
        self.assertEqual(self.buffer(b"abcd"), "abcd")
        for files in ((self.state_file,), (self.queue_state_file,),
                      (self.state_file, self.queue_state_file)):
            with self.subTest(files=[file.name for file in files]):
                for file in files:
                    file.unlink()
                os.write(self.fd, b"\x0c")
                output = self.drain()
                self.assertNotIn(b"no such file or directory", output)
                self.assertEqual(self.buffer(b""), "abcd")
                self.assertTrue(self.ready())
                self.assertFalse(self.queue_ready())
        self.assertEqual(self.buffer(b"\x15"), "")
        self.assertTrue(self.queue_ready())

    def test_deleted_launch_directory_stays_unready_during_builtin_read(self):
        shutil.rmtree(self.launch)
        os.write(self.fd, b"read -r answer\r")
        output = self.drain()
        self.assertNotIn(b"no such file or directory", output)
        self.assertFalse(self.ready())
        self.assertFalse(self.queue_ready())
        self.assertEqual(self.state_file.read_text(), "")
        self.assertEqual(self.queue_state_file.read_text(), "")
        os.write(self.fd, b"answer\r")
        output = self.wait_prompt()
        self.assertNotIn(b"no such file or directory", output)
        self.assertTrue(self.ready())
        self.assertTrue(self.queue_ready())

    def test_deleted_launch_directory_stays_unready_in_nested_shell(self):
        shutil.rmtree(self.launch)
        output = self.command("zsh -di")
        self.assertNotIn(b"no such file or directory", output)
        self.assertFalse(self.ready())
        self.assertFalse(self.queue_ready())
        output = self.command("exit")
        self.assertNotIn(b"no such file or directory", output)
        self.assertTrue(self.ready())
        self.assertTrue(self.queue_ready())

    def test_unavailable_launch_directory_fails_closed_and_retries(self):
        self.assertEqual(self.buffer(b"abcd"), "abcd")
        shutil.rmtree(self.launch)
        self.launch.write_text("blocked")
        os.write(self.fd, b"e\x14")
        output = self.drain()
        self.assertNotIn(b"not a directory", output)
        self.assertFalse(self.ready())
        self.assertFalse(self.queue_ready())
        self.assertEqual(self.buffer_file.read_text(), "abcde")
        self.launch.unlink()
        os.write(self.fd, b"f\x14")
        self.drain()
        self.assertEqual(self.buffer_file.read_text(), "abcdef")
        self.assertTrue(self.ready())
        self.assertFalse(self.queue_ready())

    def test_selection_replace_and_delete(self):
        # Place the mark at end, select the last two characters, then replace.
        self.assertEqual(self.buffer(b"abcd\x1f\x1b[D\x1b[D\x1eX"), "abX")
        self.assertEqual(self.buffer(b"\x15abcd\x1f\x1b[D\x1b[D\x1e\x7f"), "ab")

    def test_click_cancels_selection(self):
        self.assertEqual(self.buffer(b"abcd\x1f\x1b[D\x1e" + CLICK + b"X"), "abcXd")

    def test_native_zle_selection_replace_and_delete(self):
        select_left = b"\x1b[1;2D" * 2
        for edit, expected in (
            (b"X", "abX"),
            (b"\x7f", "ab"),
            (b"\x1b[3~", "ab"),
            (b"\x1b[200~paste\x1b[201~", "abpaste"),
        ):
            with self.subTest(edit=edit):
                self.assertEqual(self.buffer(b"\x15abcd" + select_left + edit), expected)

    def test_native_forward_selection_deletes_only_the_region(self):
        self.assertEqual(self.buffer(b"abcd\x01" + b"\x1b[1;2C" * 2 + b"\x7f"), "cd")

    def test_native_selection_over_the_middle_of_a_draft(self):
        draft = b"111111111222222222111111111111111"
        selection = b"\x1b[D" * 15 + b"\x1b[1;2D" * 9
        self.assertEqual(self.buffer(draft + selection + b"\x7f"), "1" * 24)

    def test_inactive_native_mark_does_not_delete_a_region(self):
        self.assertEqual(self.buffer(b"abcd" + b"\x1b[1;2D" * 2 + b"\x0fX"), "abXcd")

    def test_empty_native_region_does_not_swallow_backspace(self):
        self.assertEqual(self.buffer(b"abcd\x1b[1;2C\x7f"), "abc")

    def test_reload_keymaps_repairs_bindings(self):
        (self.original / ".zshrc").write_text("bindkey -d\n" + self.config)
        self.command('source "$ZDOTDIR/.zshrc"')
        self.assertTrue(self.ready())
        self.assertEqual(self.buffer(CLICK), "")

    def test_vi_insert_and_command_keymaps(self):
        self.command("bindkey -v")
        self.assertEqual(self.buffer(b"abc" + CLICK), "abc")
        self.assertEqual(self.buffer(b"\x1b" + CLICK), "abc")

    def test_nested_shell_disables_and_parent_recovers(self):
        self.command("zsh -di")
        self.assertFalse(self.ready())
        # Model the backend's guard: no private bytes reach an unintegrated ZLE.
        self.assertEqual(self.buffer(CLICK if self.ready() else b""), "")
        self.command("exit")
        self.assertTrue(self.ready())
        self.assertEqual(self.buffer(CLICK), "")

    def test_exec_shell_does_not_reuse_parent_pid_readiness(self):
        self.command("exec zsh -di")
        self.assertFalse(self.ready())
        self.assertEqual(self.buffer(CLICK if self.ready() else b""), "")

    def test_zsh_builtin_read_is_not_zle(self):
        os.write(self.fd, b"read -r answer\r")
        self.drain()
        self.assertFalse(self.ready())
        os.write(self.fd, b"answer\r")
        self.wait_prompt()
        self.assertTrue(self.ready())

    def test_missing_invalid_and_wrong_pid_fail_closed(self):
        self.assertFalse(self.ready(self.pid + 100000))
        for value in ("", "junk", "0", "-1"):
            self.state_file.write_text(value)
            self.assertFalse(self.ready())
        self.state_file.unlink()
        self.assertFalse(self.ready())


if __name__ == "__main__":
    unittest.main(verbosity=2)
