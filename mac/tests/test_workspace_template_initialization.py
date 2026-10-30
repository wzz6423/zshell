"""Verify the generated zsh integration runs initialization once after login."""

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


class WorkspaceTemplateInitializationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        test_prompt_selection.PromptSelectionTests.setUpClass()
        cls.addClassCleanup(test_prompt_selection.PromptSelectionTests.doClassCleanups)

    def test_initialization_runs_once_after_user_login(self):
        for mode in ("unchanged", "home", "alternate"):
            with self.subTest(mode=mode):
                self.check_initialization(mode)

    def check_initialization(self, mode):
        with tempfile.TemporaryDirectory(prefix="zshell-template-init-'", dir="/tmp") as temporary:
            root = Path(temporary)
            user = root / "user"
            launch = root / "launch"
            user.mkdir()
            launch.mkdir()
            log = root / "startup.log"
            quoted_log = shlex.quote(str(log))
            config = user
            if mode == "home":
                (user / ".zshenv").write_text('export ZDOTDIR="$HOME"\n')
            elif mode == "alternate":
                config = user / "config"
                config.mkdir()
                (user / ".zshenv").write_text('export ZDOTDIR="$HOME/config"\n')
            (config / ".zshrc").write_text(f"print -r -- rc >> {quoted_log}\nPROMPT='INIT-READY> '\n")
            (config / ".zlogin").write_text(f"print -r -- login >> {quoted_log}\nexport FROM_LOGIN=ready\n")
            integration = subprocess.check_output(
                [str(test_prompt_selection.PromptSelectionTests.helper), "generate", str(launch)], text=True
            ).strip()
            pid, descriptor = pty.fork()
            if pid == 0:
                os.environ.update(
                    HOME=str(user), ZDOTDIR=integration, ZSHELL_ORIGINAL_ZDOTDIR=str(user),
                    ZSHELL_INIT_COMMAND=f'print -r -- "init:$FROM_LOGIN" >> {quoted_log}; typeset FROM_INIT=ready',
                    TERM="xterm-256color", LC_ALL="en_US.UTF-8",
                )
                os.execv("/bin/zsh", ["zsh", "-dil"])
            try:
                def wait_prompt():
                    output = b""
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        if select.select([descriptor], [], [], 0.05)[0]:
                            output += os.read(descriptor, 65536)
                            if b"INIT-READY> " in output:
                                return
                    self.fail(f"No prompt: {output!r}")

                wait_prompt()
                self.assertEqual(log.read_text().splitlines(), ["rc", "login", "init:ready"])
                check = f'print -r -- "state:$ZDOTDIR:$FROM_INIT" >> {quoted_log}\r'
                os.write(descriptor, check.encode())
                wait_prompt()
                self.assertEqual(log.read_text().splitlines(), ["rc", "login", "init:ready", f"state:{config}:ready"])
            finally:
                os.close(descriptor)
                try:
                    os.kill(pid, signal.SIGHUP)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)


if __name__ == "__main__":
    unittest.main()
