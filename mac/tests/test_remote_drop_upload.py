"""Exercise production remote paste and native file drops through disposable SSH.

Build Debug in isolated DerivedData first. Both terminal backends use the real
OpenSSH transport and bundled server. No user SSH files or app windows change.
"""

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_browser_remote_routing import Fixture, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--backend", choices=("alacritty", "ghostty"), action="append")
    options = parser.parse_args()
    server = options.derived_data.resolve() / "Build/Products/Debug/zshell Debug.app/Contents/Resources/zshell-server"
    if not server.is_file():
        raise SystemExit(f"Build Debug in {options.derived_data} first")
    with tempfile.TemporaryDirectory(prefix="zshell-remote-drop-", dir="/tmp") as temporary:
        directory = Path(temporary)
        ssh = directory / "ssh"
        ssh.mkdir()
        fixture = Fixture(ssh)
        daemon = None
        try:
            fixture.__enter__()
            home = directory / "remote-home"
            home.mkdir()
            (home / ".zshenv").write_text("HISTFILE=/dev/null\n")
            project = home / "project"
            project.mkdir()
            state = directory / "rs"
            wrapper = directory / "zshell-server"
            wrapper.write_text("#!/bin/sh\nexport HOME=" + shlex.quote(str(home))
                               + " ZDOTDIR=" + shlex.quote(str(home))
                               + "\nexec " + shlex.join([str(server), "--state", str(state)]) + ' "$@"\n')
            wrapper.chmod(0o755)
            environment = {**os.environ, "HOME": str(home), "ZDOTDIR": str(home)}
            with (directory / "server.log").open("wb") as log:
                daemon = subprocess.Popen([str(server), "serve", "--state", str(state)],
                                          cwd=ROOT, env=environment, stdout=log, stderr=log)
            arguments = [sys.executable, str(ROOT / "mac/tests/test_remote_session_surfaces.py"),
                         "--derived-data", str(options.derived_data.resolve()), "--address", fixture.address,
                         "--directory", str(project), "--ssh-config", str(fixture.config),
                         "--server-path", str(wrapper), "--paste-only"]
            for backend in options.backend or ():
                arguments += ["--backend", backend]
            subprocess.run(arguments, cwd=ROOT, check=True, timeout=400)
        finally:
            if daemon is not None:
                subprocess.run([str(server), "stop", "--state", str(directory / "rs")],
                               capture_output=True, timeout=10)
                if daemon.poll() is None:
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait()
            fixture.__exit__()


if __name__ == "__main__":
    main()
