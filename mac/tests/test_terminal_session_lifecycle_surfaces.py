"""Exercise terminal close, preserve, remote detach and actual AppKit quit.

Requires an existing signed Debug app. Native surfaces run offscreen; SSH uses
an isolated loopback host with a pinned test key. Every process, binary, cache,
settings directory and remote PTY belongs to the fixture and is cleaned up.
"""

import argparse
import ctypes
import getpass
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments


ROOT = Path(__file__).resolve().parents[2]


class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "exit_status", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("files", "pgid", "job_count", "tty", "tty_pgid")]
    _fields_ += [("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")


def identity(pid):
    info = ProcessInfo()
    count = LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count != ctypes.sizeof(info) or info.status == 5:
        return None
    return {"pid": pid, "seconds": info.seconds, "microseconds": info.microseconds}


def matches(expected):
    current = identity(expected["pid"])
    return current is not None and all(current[key] == expected[key] for key in ("pid", "seconds", "microseconds"))


def cleanup_processes(home):
    evidence = home / "process-identities.json"
    if not evidence.exists():
        return
    captured = json.loads(evidence.read_text())
    scopes = {process["session"] for process in captured if "session" in process and matches(process)}
    count = LIBPROC.proc_listallpids(None, 0)
    if count > 0 and scopes:
        pids = (ctypes.c_int32 * (count + 32))()
        written = LIBPROC.proc_listallpids(pids, ctypes.sizeof(pids))
        for pid in list(pids)[:written]:
            try:
                belongs = pid > 1 and os.getsid(pid) in scopes
            except ProcessLookupError:
                continue
            if belongs:
                process = identity(pid)
                if process is not None:
                    process["session"] = os.getsid(pid)
                    captured.append(process)
    for process in captured:
        if matches(process):
            try:
                if "session" in process and os.getsid(process["pid"]) != process["session"]:
                    continue
                os.kill(process["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", type=Path, required=True)
    parser.add_argument("--case", choices=("close", "quit", "quit-all", "quit-overlay"), action="append")
    options = parser.parse_args()
    app = options.built_app.resolve()
    cases = options.case or ("close", "quit", "quit-all", "quit-overlay")
    with tempfile.TemporaryDirectory(prefix="zshell-terminal-lifecycle-", dir="/tmp") as directory:
        temporary = Path(directory)
        contents = temporary / "LifecycleTests.app/Contents"
        binary = contents / "MacOS/lifecycle-tests"
        binary.parent.mkdir(parents=True)
        (contents / "Resources").symlink_to(app / "Contents/Resources", target_is_directory=True)
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        metadata.update(CFBundleIdentifier="sh.zshell.terminal-lifecycle-test." + uuid.uuid4().hex,
                        CFBundleExecutable=binary.name, LSUIElement=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps(metadata))
        command = compiler_arguments(temporary) + built_app_arguments(app)
        command += [str(ROOT / "mac/tests/TerminalSessionLifecycleSurfaceTests.swift"),
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
        wrapper = temporary / "zshell-server"
        wrapper.write_text("#!/bin/sh\nexport HOME=" + shlex.quote(str(remote_home))
                           + " ZDOTDIR=" + shlex.quote(str(remote_home))
                           + " ZSHELL_REMOTE_STATE=" + shlex.quote(str(temporary / "remote-state"))
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
            for backend in ("libghostty", "alacritty"):
                for case in cases:
                    home = temporary / f"{backend}-{case}"
                    home.mkdir()
                    (home / "tmp").mkdir()
                    (home / ".zshenv").write_text("export HOME=" + shlex.quote(str(home)) + "\nHISTFILE=/dev/null\n")
                    config = home / ".config/zshell-dev/config.toml"
                    config.parent.mkdir(parents=True)
                    config.write_text("ai.enabled = false\nquick-terminal.enabled = false\n")
                    environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
                    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                                       TMPDIR=str(home / "tmp") + "/", ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"),
                                       ZSHELL_SSH_AGENT_RESOLVED="1", ZSHELL_SSH_CONFIG_FILE=str(ssh_config),
                                       ZSHELL_LIFECYCLE_REMOTE_ADDRESS=f"ssh://{getpass.getuser()}@127.0.0.1:{port}",
                                       ZSHELL_LIFECYCLE_REMOTE_DIRECTORY=str(remote_home),
                                       ZSHELL_LIFECYCLE_REMOTE_SERVER=str(wrapper))
                    try:
                        subprocess.run([str(binary), backend, str(home), case], cwd=ROOT, env=environment,
                                       check=True, timeout=120)
                        if case.startswith("quit"):
                            processes = json.loads((home / "process-identities.json").read_text())
                            deadline = time.monotonic() + 2
                            while any(matches(process) for process in processes) and time.monotonic() < deadline:
                                time.sleep(0.01)
                            if any(matches(process) for process in processes):
                                raise AssertionError(f"{backend}: actual AppKit quit left its background group alive")
                            print(f"PASS {backend} {case}: actual AppKit quit stops every recorded shell and background group", flush=True)
                    finally:
                        cleanup_processes(home)
                        mux = [str(app / "Contents/MacOS/zshell"), "+pty-mux"]
                        listing = subprocess.run(mux + ["list"], capture_output=True, text=True, env=environment, timeout=10)
                        if listing.returncode == 0:
                            for session in json.loads(listing.stdout):
                                subprocess.run(mux + ["terminate", session["id"]], capture_output=True,
                                               env=environment, timeout=10, check=True)
                            time.sleep(0.35)
                            subprocess.run(mux + ["shutdown"], capture_output=True, env=environment, timeout=10, check=True)
        finally:
            subprocess.run([str(wrapper), "stop"], capture_output=True, timeout=12)
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()


if __name__ == "__main__":
    main()
