"""Apply remote workspace templates through a loopback OpenSSH fixture.

Build Debug first, then set ZSHELL_TEST_DERIVED_DATA to that build. The script
starts an unprivileged sshd on 127.0.0.1 with disposable host and client keys,
points the app at it through ZSHELL_SSH_CONFIG_FILE, and runs the bundled
zshell-server with a disposable HOME and state directory. No user SSH files,
saved hosts or live app windows are read or changed; everything is removed
afterwards.
"""

import getpass
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import socket
import stat
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
BUILD = Path(os.environ.get("ZSHELL_TEST_DERIVED_DATA", ROOT / "mac/build/debug")) / "Build"
PRODUCTS = BUILD / "Products/Debug"
APP = PRODUCTS / "zshell Debug.app"
LIBRARY = APP / "Contents/MacOS/zshell.debug.dylib"
SERVER = APP / "Contents/Resources/zshell-server"
if not LIBRARY.is_file() or not SERVER.is_file():
    raise SystemExit(f"Build the Debug app in {BUILD.parent} first.")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


with tempfile.TemporaryDirectory(prefix="zshell-template-remote-", dir="/tmp") as directory:
    temporary = Path(os.path.realpath(directory))
    ssh = temporary / "ssh"
    ssh.mkdir(mode=0o700)
    for key in ("host_key", "client_key"):
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(ssh / key)], check=True)
    shutil.copy(ssh / "client_key.pub", ssh / "authorized_keys")
    port = free_port()
    (ssh / "sshd_config").write_text("\n".join([
        f"ListenAddress 127.0.0.1", f"Port {port}", f"HostKey {ssh / 'host_key'}",
        f"PidFile {ssh / 'sshd.pid'}", f"AuthorizedKeysFile {ssh / 'authorized_keys'}",
        f"AllowUsers {getpass.getuser()}", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
        "UsePAM no", "StrictModes no", "PermitUserRC no", "PermitUserEnvironment no",
        "AllowTcpForwarding no", "AllowAgentForwarding no", "X11Forwarding no", "PermitTTY yes", "",
    ]))
    (ssh / "known_hosts").write_text(f"[127.0.0.1]:{port} " + (ssh / "host_key.pub").read_text())
    config = ssh / "ssh_config"
    config.write_text("\n".join([
        "Host template-fixture", "  HostName 127.0.0.1", f"  Port {port}", f"  User {getpass.getuser()}",
        f"  IdentityFile {ssh / 'client_key'}", "  IdentitiesOnly yes", "  IdentityAgent none",
        f"  UserKnownHostsFile {ssh / 'known_hosts'}", "  GlobalKnownHostsFile /dev/null",
        "  BatchMode yes", "  ControlMaster no", "  ControlPath none", "",
    ]))
    remote_home = temporary / "remote-home"
    remote_home.mkdir()
    (remote_home / ".zshenv").write_text("HISTFILE=/dev/null\n")
    (remote_home / ".zshrc").write_text("PROMPT='REMOTE> '; RPROMPT=''\n")
    remote_state = temporary / "rs"
    wrapper = temporary / "zshell-server"
    wrapper.write_text(f"#!/bin/sh\nexport HOME='{remote_home}' ZDOTDIR='{remote_home}' ZSHELL_REMOTE_STATE='{remote_state}'\n"
                       f"exec '{SERVER}' \"$@\"\n")
    wrapper.chmod(0o755)

    bundle = temporary / "WorkspaceTemplateRemoteTests.app/Contents"
    binary = bundle / "MacOS/WorkspaceTemplateRemoteTests"
    binary.parent.mkdir(parents=True)
    bundle_identifier = "sh.zshell.template-test." + uuid.uuid4().hex
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_identifier, "CFBundleExecutable": binary.name,
        "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    (bundle / "Resources").symlink_to(APP / "Contents/Resources")
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
        "-I", str(PRODUCTS), "-I", str(PRODUCTS / "include"), "-F", str(PRODUCTS),
    ]
    for modulemap in (BUILD / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap"):
        command += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in (
        "STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
        "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include",
    ):
        path = ROOT / "mac/Vendor" / include
        command += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    command += [
        "-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"),
        str(LIBRARY), "-Xlinker", "-rpath", "-Xlinker", str(PRODUCTS),
        "-Xlinker", "-rpath", "-Xlinker", str(LIBRARY.parent),
        str(ROOT / "mac/tests/WorkspaceTemplateRemoteSurfaceTests.swift"),
        str(ROOT / "mac/tests/QuickTerminalOffscreen.swift"), "-o", str(binary),
    ]
    subprocess.run(command, cwd=ROOT, check=True)

    daemon = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(ssh / "sshd_config")],
                              stdout=subprocess.DEVNULL, stderr=open(ssh / "sshd.log", "w"))
    try:
        deadline = time.time() + 10
        while subprocess.run(["/usr/bin/ssh", "-F", str(config), "template-fixture", "true"],
                             capture_output=True, timeout=15).returncode != 0:
            if time.time() > deadline or daemon.poll() is not None:
                raise SystemExit("The loopback sshd fixture did not accept the test key:\n" + (ssh / "sshd.log").read_text())
            time.sleep(0.2)
        for backend in ("alacritty", "ghostty"):
            home = temporary / backend
            (home / "tmp").mkdir(parents=True)
            settings = home / ".config/zshell-dev"
            settings.mkdir(parents=True)
            (settings / "config.toml").write_text("[ai]\nenabled = false\n")
            startup = 'export HOME="$CFFIXED_USER_HOME"\nexport ZDOTDIR="$HOME"\nHISTFILE=/dev/null\n'
            (home / ".zshenv").write_text(startup)
            (home / ".zshrc").write_text(startup + "PROMPT='TEMPLATE-READY> '; RPROMPT=''\n")
            results = home / "results"
            results.mkdir()
            environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
            environment.update({
                "HOME": str(home), "CFFIXED_USER_HOME": str(home), "ZDOTDIR": str(home),
                "TMPDIR": str(home / "tmp") + "/", "ZSHELL_PTY_MUX_DIRECTORY": str(home / "pty"),
                "ZSHELL_SSH_CONFIG_FILE": str(config),
                "ZSHELL_TEMPLATE_TEST_VISIBLE": os.environ.get("ZSHELL_TEMPLATE_TEST_VISIBLE", "0"),
            })
            print(f"RUN remote workspace template surfaces {backend}", flush=True)
            try:
                with subprocess.Popen([str(binary), backend, str(home), "ssh://template-fixture", str(wrapper),
                                       str(remote_home), str(results)],
                                      cwd=ROOT, env=environment, start_new_session=True) as fixture:
                    try:
                        code = fixture.wait(timeout=180)
                        if code != 0:
                            raise subprocess.CalledProcessError(code, fixture.args)
                    finally:
                        if fixture.poll() is None:
                            os.killpg(fixture.pid, signal.SIGTERM)
                            try:
                                fixture.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(fixture.pid, signal.SIGKILL)
                                fixture.wait()
                        for leftover in Path("/tmp").glob(f"zshell-{os.getuid()}-{fixture.pid}-*.sock"):
                            if stat.S_ISSOCK(leftover.lstat().st_mode):
                                leftover.unlink()
                if artifacts := os.environ.get("ZSHELL_TEMPLATE_TEST_ARTIFACTS"):
                    destination = Path(artifacts)
                    destination.mkdir(parents=True, exist_ok=True)
                    for screenshot in results.glob("*.png"):
                        shutil.copy2(screenshot, destination / screenshot.name)
            finally:
                cli = [str(APP / "Contents/MacOS/zshell"), "+pty-mux"]
                listing = subprocess.run(cli + ["list"], cwd=ROOT, env=environment,
                                         capture_output=True, text=True, timeout=10)
                if listing.returncode == 0:
                    for session in json.loads(listing.stdout):
                        subprocess.run(cli + ["terminate", session["id"]], cwd=ROOT,
                                       env=environment, capture_output=True, timeout=10)
                    subprocess.run(cli + ["shutdown"], cwd=ROOT, env=environment, capture_output=True, timeout=10)
    finally:
        subprocess.run([str(wrapper), "stop"], capture_output=True, timeout=15)
        stop(daemon)
        subprocess.run(["/usr/bin/defaults", "delete", bundle_identifier], capture_output=True, timeout=10)
        (Path.home() / "Library/Preferences" / f"{bundle_identifier}.plist").unlink(missing_ok=True)
