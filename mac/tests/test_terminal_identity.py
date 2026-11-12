"""Verify native TERM settings and real PTYs using an existing signed Debug app.

Run with --built-app after the Debug build. Binaries, homes, shells and mux
daemons are disposable; the integration fixture does not show user windows.
"""

import argparse
import getpass
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", type=Path, required=True)
    options = parser.parse_args()
    app = options.built_app.resolve()
    with tempfile.TemporaryDirectory(prefix="zshell-term-", dir="/tmp") as directory:
        temporary = Path(directory)
        contents = temporary / "TerminalIdentity.app/Contents"
        binary = contents / "MacOS/terminal-identity"
        binary.parent.mkdir(parents=True)
        (contents / "Resources").symlink_to(app / "Contents/Resources", target_is_directory=True)
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        metadata.update(CFBundleIdentifier="sh.zshell.terminal-identity-test." + uuid.uuid4().hex,
                        CFBundleExecutable=binary.name, LSUIElement=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
        command = compiler_arguments(temporary) + built_app_arguments(app)
        command += [str(ROOT / "mac/tests/TerminalIdentityTests.swift"),
                    str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary)]
        subprocess.run(command, check=True, cwd=ROOT, timeout=120)
        ssh = temporary / "ssh"
        ssh.mkdir(mode=0o700)
        for key in ("host_key", "client_key"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(ssh / key)], check=True)
        shutil.copy(ssh / "client_key.pub", ssh / "authorized_keys")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        (ssh / "sshd_config").write_text("\n".join([
            "ListenAddress 127.0.0.1", f"Port {port}", f"HostKey {ssh / 'host_key'}",
            f"PidFile {ssh / 'sshd.pid'}", f"AuthorizedKeysFile {ssh / 'authorized_keys'}",
            f"AllowUsers {getpass.getuser()}", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
            "UsePAM no", "StrictModes no", "PermitUserRC no", "PermitUserEnvironment no",
            "AllowTcpForwarding no", "AllowAgentForwarding no", "X11Forwarding no", "PermitTTY yes", "",
        ]))
        (ssh / "known_hosts").write_text(f"[127.0.0.1]:{port} " + (ssh / "host_key.pub").read_text())
        ssh_config = ssh / "ssh_config"
        ssh_config.write_text("\n".join([
            "Host *", f"  User {getpass.getuser()}", f"  Port {port}",
            f"  IdentityFile {ssh / 'client_key'}", "  IdentitiesOnly yes", "  IdentityAgent none",
            f"  UserKnownHostsFile {ssh / 'known_hosts'}", "  GlobalKnownHostsFile /dev/null",
            "  BatchMode yes", "  ControlMaster no", "  ControlPath none", "",
        ]))
        remote_home = temporary / "remote-home"
        remote_home.mkdir()
        (remote_home / ".zshenv").write_text("HISTFILE=/dev/null\n")
        remote_state = temporary / "rs"
        wrapper = temporary / "zshell-server"
        wrapper.write_text("#!/bin/sh\nexport HOME=" + shlex.quote(str(remote_home))
                           + " ZDOTDIR=" + shlex.quote(str(remote_home))
                           + " ZSHELL_REMOTE_STATE=" + shlex.quote(str(remote_state))
                           + "\nexec " + shlex.quote(str(app / "Contents/Resources/zshell-server")) + ' "$@"\n')
        wrapper.chmod(0o755)
        with (ssh / "sshd.log").open("wb") as ssh_log:
            daemon = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(ssh / "sshd_config")],
                                      stdout=ssh_log, stderr=ssh_log)
        try:
            deadline = time.monotonic() + 8
            while subprocess.run(["/usr/bin/ssh", "-F", str(ssh_config), "127.0.0.1", "true"],
                                 capture_output=True, timeout=12).returncode != 0:
                if time.monotonic() > deadline or daemon.poll() is not None:
                    raise RuntimeError((ssh / "sshd.log").read_text())
                time.sleep(0.1)
            run_backends(app, binary, temporary, ssh_config, wrapper, remote_home, port)
        finally:
            subprocess.run([str(wrapper), "stop"], capture_output=True, timeout=12)
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()


def run_backends(app, binary, temporary, ssh_config, wrapper, remote_home, port):
    for backend in ("libghostty", "alacritty"):
        home = temporary / backend
        home.mkdir()
        (home / "tmp").mkdir()
        config = home / ".config/zshell-dev/config.toml"
        config.parent.mkdir(parents=True)
        config.write_text("ai.enabled = false\n")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           TMPDIR=str(home / "tmp") + "/", ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"),
                           ZSHELL_SSH_AGENT_RESOLVED="1", ZSHELL_SSH_CONFIG_FILE=str(ssh_config),
                           ZSHELL_TERM_TEST_REMOTE_ADDRESS=f"ssh://{getpass.getuser()}@127.0.0.1:{port}",
                           ZSHELL_TERM_TEST_REMOTE_DIRECTORY=str(remote_home),
                           ZSHELL_TERM_TEST_REMOTE_SERVER=str(wrapper),
                           ZSHELL_TERM_TEST_SSH_USER=getpass.getuser(), ZSHELL_TERM_TEST_SSH_PORT=str(port))
        try:
            subprocess.run([str(binary), backend, str(home)], check=True, cwd=ROOT,
                           env=environment, timeout=140)
        finally:
            mux = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]
            listing = subprocess.run(mux + ["list"], capture_output=True, text=True,
                                     env=environment, cwd=ROOT, timeout=10)
            if listing.returncode == 0:
                for session in json.loads(listing.stdout):
                    subprocess.run(mux + ["terminate", session["id"]], capture_output=True,
                                   env=environment, cwd=ROOT, timeout=10, check=True)
                time.sleep(0.35)
                subprocess.run(mux + ["shutdown"], capture_output=True,
                               env=environment, cwd=ROOT, timeout=10, check=True)


if __name__ == "__main__":
    main()
