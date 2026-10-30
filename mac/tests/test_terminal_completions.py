"""Exercise bundled completion and production startup in disposable zsh PTYs."""

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

import test_prompt_selection


class TerminalCompletionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        test_prompt_selection.PromptSelectionTests.setUpClass()
        cls.addClassCleanup(test_prompt_selection.PromptSelectionTests.doClassCleanups)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zshell-completions-'", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user = self.root / "user"
        self.user.mkdir()
        self.launch = self.root / "launch"
        self.launch.mkdir(mode=0o700)
        self.dump = self.root / "dump"
        self.sentinel = self.root / "executed"
        self.pid = self.fd = None
        self.addCleanup(self.close_shell)

    def start(self, configuration="", enabled=True):
        config = (
            "bindkey -e; PROMPT='READY> '; RPROMPT=''; HISTFILE=/dev/null\n"
            "autoload -Uz compinit; compinit -D -i\n"
            "_fixture() { compadd alpha bravo; }; compdef _fixture zfixture\n"
            f"zfixture() {{ print ran >| {shlex.quote(str(self.sentinel))}; }}\n"
            "_options_fixture() { _arguments '--format[format]:format:(json yaml)' '*:file:_files'; }; "
            "compdef _options_fixture zoptions\n"
            f"_dump() {{ print -rn -- \"$BUFFER\"$'\\0'\"$CURSOR\"$'\\0'\"$POSTDISPLAY\" >| {shlex.quote(str(self.dump))}; }}\n"
            "zle -N _dump; for map in emacs viins vicmd; do bindkey -M $map '^T' _dump; done\n" + configuration
        )
        (self.user / ".zshrc").write_text(config)
        self.original_config = config
        integration = subprocess.check_output([
            str(test_prompt_selection.PromptSelectionTests.helper), "generate-completions" if enabled else "generate",
            str(self.launch),
        ], text=True).strip()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.user)
            os.environ.update(HOME=str(self.user), ZDOTDIR=integration,
                              ZSHELL_ORIGINAL_ZDOTDIR=str(self.user), TERM="xterm-256color",
                              LC_ALL="en_US.UTF-8")
            os.execv("/bin/zsh", ["zsh", "-dil"])
        output = self.drain(0.6)
        self.assertIn(b"READY> ", output)
        self.assertNotIn(b"error", output)

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

    def drain(self, duration=0.12):
        output = bytearray()
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], 0.01)[0]:
                output.extend(os.read(self.fd, 65536))
        return bytes(output)

    def keys(self, value, duration=0.15):
        os.write(self.fd, value.encode() if isinstance(value, str) else value)
        return self.drain(duration)

    def state(self):
        self.dump.unlink(missing_ok=True)
        self.keys(b"\x14")
        buffer, cursor, suggestion = self.dump.read_bytes().split(b"\0")
        return buffer.decode(), int(cursor), suggestion.decode()

    def test_inline_and_menu_selection_accept_without_execution(self):
        self.start()
        output = self.keys("zfixture ", 0.5)
        self.assertIn(b"alpha", output)
        self.assertEqual(self.state(), ("zfixture ", 9, "alpha"))
        menu = self.keys(b"\t")
        self.assertIn(b"alpha", menu)
        self.assertIn(b"bravo", menu)
        self.keys(b"\x1b[C\r")
        self.assertEqual(self.state()[0], "zfixture bravo ")
        self.assertFalse(self.sentinel.exists())

    def test_menu_cancel_restores_draft(self):
        self.start()
        for cancel in (b"\x07", b"\x1b"):
            self.keys(b"\x15zfixture ", 0.3)
            self.keys(b"\t")
            self.keys(cancel, 0.5)
            self.assertEqual(self.state()[0], "zfixture ")
            self.assertFalse(self.sentinel.exists())

    def test_inline_accept_and_dismiss(self):
        self.start()
        self.keys("zfixture ", 0.4)
        self.keys(b"\x1b[C")
        self.assertEqual(self.state()[0], "zfixture alpha")
        self.keys(b"\x15zfixture ", 0.4)
        self.keys(b"\x1b", 0.5)
        self.assertEqual(self.state()[0::2], ("zfixture ", ""))
        self.keys("b", 0.4)
        self.assertEqual(self.state()[2], "ravo")

    def test_arguments_use_registered_completion(self):
        self.start()
        self.keys("zoptions --format j", 0.4)
        self.assertEqual(self.state()[2], "son")
        self.keys(b"\t")
        self.assertEqual(self.state()[0], "zoptions --format json ")

    def test_unicode_paths_spaces_and_quoting(self):
        self.start()
        for name in ("中文 file.txt", "quote'file.txt", "literal$(touch sentinel).txt"):
            (self.user / name).touch()
        for draft, expected in [
            ("cat 中", "cat 中文\\ file.txt "),
            ("cat '中", "cat '中文 file.txt' "),
            ("cat quote", "cat quote\\'file.txt "),
            ("cat literal", "cat literal\\$\\(touch\\ sentinel\\).txt "),
        ]:
            with self.subTest(draft=draft):
                self.keys(b"\x15")
                self.keys(draft, 0.35)
                self.keys(b"\t")
                self.assertEqual(self.state()[0], expected)
                self.assertFalse((self.user / "sentinel").exists())

    def test_middle_cursor_completion_preserves_suffix(self):
        self.start()
        self.keys("zoptions --format j --other", 0.3)
        self.keys(b"\x1b[D" * 8, 0.25)
        self.assertEqual(self.state()[2], "")
        self.keys(b"\t")
        self.assertEqual(self.state()[0].split(), ["zoptions", "--format", "json", "--other"])

    def test_existing_widgets_and_compinit_are_preserved(self):
        self.start("_custom_tab() { LBUFFER+='USER'; }; zle -N _custom_tab; bindkey '^I' _custom_tab\n"
                   "_user_suggest() { POSTDISPLAY='USER_HINT'; }; zle -N user-autosuggest _user_suggest\n"
                   "_user_self() { zle .self-insert; _user_suggest; }; zle -N self-insert _user_self\n")
        self.keys("zfixture ")
        self.assertEqual(self.state()[2], "USER_HINT")
        self.keys(b"\t")
        self.assertEqual(self.state()[0], "zfixture USER")
        self.assertEqual((self.user / ".zshrc").read_text(), self.original_config)
        self.assertFalse((self.user / ".zcompdump").exists())

    def test_disabled_setting_keeps_shell_unchanged(self):
        self.start(enabled=False)
        self.keys("zfixture ", 0.4)
        self.assertEqual(self.state()[2], "")

    def test_shell_completion_is_broad_and_bundled(self):
        self.start()
        self.keys("brew --ver", 0.4)
        self.keys(b"\t")
        self.assertEqual(self.state()[0], "brew --version ")
        self.keys(b"\x15zfix", 0.4)
        self.assertEqual(self.state()[2], "ture")

    def test_xcode_remote_bundle_declares_every_completion_resource(self):
        mac = Path(__file__).resolve().parents[1]
        resources = mac / "zshell/ShellIntegration/TerminalCompletions"
        files = [resources, resources / "completions", *resources.rglob("*")]
        expected = {"$(SRCROOT)/" + str(path.relative_to(mac)) for path in files}
        declared = set((mac / "scripts/terminal-completions.xcfilelist").read_text().splitlines())
        self.assertEqual(declared, expected)

    def test_control_keys_and_vi_mode(self):
        self.start()
        self.keys("zfixture ", 0.3)
        self.keys(b"\x01X\x05", 0.3)
        self.assertTrue(self.state()[0].startswith("Xzfixture "))
        self.keys(b"\x03", 0.3)
        self.assertIn(b"READY> ", self.keys(b"\x15bindkey -v\r", 0.3))
        self.keys("zfixture ", 0.3)
        self.keys(b"\t\x1b[C\r")
        self.assertEqual(self.state()[0], "zfixture bravo ")
        self.assertFalse(self.sentinel.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
