"""Exercise the app's generated integration and readiness check against macOS ZLE.

Run: python3 mac/tests/test_prompt_selection.py
Only the standard library, swiftc, and /bin/zsh are required.
"""
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
        helper.write_text("import Foundation\nstruct Surface { var foregroundPid: pid_t? }\n"
                          "struct Session {\nvar hasExited = false\n"
                          "var launchDirectoryURL: URL?\nvar surface: Surface\n"
                          + generator.replace("private static func", "static func")
                          + readiness + "\n}\n"
                          'let directory = URL(fileURLWithPath: CommandLine.arguments[2])\n'
                          'if CommandLine.arguments[1] == "generate" {\n'
                          'print(try Session.makeShellIntegrationArtifacts(in: directory, shellPath: "/bin/zsh")!.path)\n'
                          '} else {\n'
                          'print(Session(launchDirectoryURL: directory, surface: Surface(foregroundPid: pid_t(CommandLine.arguments[3]))).terminalPromptSelectionIsReady)\n}\n')
        cls.helper = Path(cls.build.name) / "integration"
        subprocess.run(["swiftc", str(helper), "-o", str(cls.helper)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zshell-prompt-'")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.original = self.root / "user"
        self.original.mkdir()
        self.buffer_file = self.root / "buffer"
        self.state_file = self.root / "prompt-selection.pid"
        self.config = (
            "bindkey -e\nPROMPT='READY> '\nRPROMPT=''\n"
            f"_dump() {{ print -rn -- \"$BUFFER\" >| {shlex.quote(str(self.buffer_file))}; }}\n"
            "zle -N _dump\n"
            "for map in emacs viins vicmd; do bindkey -M $map '^T' _dump; done\n"
        )
        (self.original / ".zshrc").write_text(self.config)
        integration = subprocess.check_output(
            [str(self.helper), "generate", str(self.root)], text=True).strip()
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
                    self.drain()
                    return
        self.fail(f"No prompt: {output!r}")

    def drain(self):
        while select.select([self.fd], [], [], .05)[0]:
            os.read(self.fd, 65536)

    def command(self, command):
        os.write(self.fd, command.encode() + b"\r")
        self.wait_prompt()

    def ready(self, pid=None):
        return subprocess.check_output(
            [str(self.helper), "ready", str(self.root), str(pid or self.pid)],
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

    def test_selection_replace_and_delete(self):
        # Place the mark at end, select the last two characters, then replace.
        self.assertEqual(self.buffer(b"abcd\x1f\x1b[D\x1b[D\x1eX"), "abX")
        self.assertEqual(self.buffer(b"\x15abcd\x1f\x1b[D\x1b[D\x1e\x7f"), "ab")

    def test_click_cancels_selection(self):
        self.assertEqual(self.buffer(b"abcd\x1f\x1b[D\x1e" + CLICK + b"X"), "abcXd")

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
