"""Verify original Bash command events and retained tasks on both native backends.

Build Debug first, then pass --built-app. Each probe uses a disposable HOME,
preferences and PTY; the user's app and foreground window remain unchanged.
"""

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--built-app", type=Path, required=True)
parser.add_argument("--backend", choices=("ghostty", "alacritty"), action="append")
parser.add_argument("--persistent-input", action="store_true")
options = parser.parse_args()
app = options.built_app.resolve()
with tempfile.TemporaryDirectory(prefix="zshell-bash-surface-tests-", dir="/tmp") as directory:
    temporary = Path(directory)
    contents = temporary / "BashProbe.app/Contents"
    binary = contents / "MacOS/bash-probe"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to(app / "Contents/Resources", target_is_directory=True)
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    domain = "sh.zshell.bash-surface-test." + uuid.uuid4().hex
    metadata.update(CFBundleIdentifier=domain, CFBundleExecutable=binary.name, LSUIElement=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
    command = compiler_arguments(temporary) + built_app_arguments(app)
    command += [str(ROOT / ("mac/tests/TerminalBashPersistentInputTests.swift" if options.persistent_input else "mac/tests/TerminalBashCommandSurfaceTests.swift")),
                str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
    subprocess.run(command, check=True, cwd=ROOT, timeout=120)
    try:
        for backend in (["persistent"] if options.persistent_input else options.backend or ("alacritty", "ghostty")):
            home = temporary / backend
            (home / "fixture").mkdir(parents=True)
            (home / "tmp").mkdir()
            config = home / ".config/zshell-dev/config.toml"
            config.parent.mkdir(parents=True)
            config.write_text("ai.enabled = false\nquick-terminal.enabled = false\n"
                              "terminal.preserve-sessions = false\nterminal.restore-history = false\n")
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(("ZSHELL_", "GHOSTTY_")) and key not in ("PROMPT_COMMAND", "BASH_ENV", "ENV")}
            environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                               XDG_CONFIG_HOME=str(home / ".config"), XDG_DATA_HOME=str(home / ".local/share"),
                               TMPDIR=str(home / "tmp") + "/", ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"))
            subprocess.run([str(binary), str(home / "fixture"), backend], check=True,
                           cwd=ROOT, env=environment, timeout=120)
    finally:
        subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
