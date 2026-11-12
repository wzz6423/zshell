"""Run remote file operations through the production SSH command transport.

The SSH executable is replaced by a local shell, with no server, credentials,
GUI, or personal configuration. All binaries and fixtures are temporary.
"""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="zshell-remote-file-tests-", dir="/tmp") as directory:
        temporary = Path(directory).resolve()
        support = temporary / "Support.swift"
        support.write_text("import Foundation\nnonisolated struct RemoteHost: Codable, Equatable, Sendable {}\n")
        ssh = temporary / "fixture-ssh"
        ssh.write_text("#!/bin/sh\nfor argument do command=\"$argument\"; done\nHOME=\"$ZSHELL_REMOTE_FIXTURE_HOME\" exec /bin/sh -c \"$command\"\n")
        ssh.chmod(0o700)
        missing = temporary / "missing-tools-ssh"
        missing.write_text("#!/bin/sh\nfor argument do command=\"$argument\"; done\ncase \"$command\" in *'command -v perl'*) exit 69 ;; esac\nexec /bin/sh -c \"$command\"\n")
        missing.chmod(0o700)
        (temporary / "NoAtomicRename.pm").write_text("package NoAtomicRename; use Errno (); BEGIN { *CORE::GLOBAL::syscall = sub { $! = Errno::ENOSYS(); return -1; }; } 1;\n")
        limited = temporary / "limited-tools-ssh"
        limited.write_text(f"#!/bin/sh\nfor argument do command=\"$argument\"; done\nPERL5LIB='{temporary}' PERL5OPT=-MNoAtomicRename exec /bin/sh -c \"$command\"\n")
        limited.chmod(0o700)
        invalid = temporary / "invalid-names-ssh"
        invalid.write_text("#!/bin/sh\nprintf '0\\000\\377\\000'\n")
        invalid.chmod(0o700)
        configuration = temporary / "ssh_config"
        configuration.write_text("Host fixture.invalid\n    HostName fixture.invalid\n")
        environment = dict(os.environ)
        environment.update({"ZSHELL_SSH_CONFIG_FILE": str(configuration), "ZSHELL_SSH_AGENT_RESOLVED": "1"})
        fixture_home = temporary / "remote-home"
        fixture_home.mkdir()
        environment["ZSHELL_REMOTE_FIXTURE_HOME"] = str(fixture_home)
        environment.pop("SSH_AUTH_SOCK", None)
        binary = temporary / "remote-file-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
            "-warnings-as-errors", "-O", "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/RemoteSSH.swift"), str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
            str(ROOT / "mac/zshell/FileSaveCoordinator.swift"), str(ROOT / "mac/zshell/RemoteFileService.swift"),
            str(support), str(ROOT / "mac/tests/RemoteFileServiceTests.swift"), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        with tempfile.TemporaryDirectory(prefix=".zshell-remote-file-test-", dir=Path.home()) as named_home:
            subprocess.run([str(binary), str(temporary), str(ssh), str(missing), str(limited), named_home, str(invalid)],
                           cwd=ROOT, env=environment, check=True, timeout=90)


if __name__ == "__main__":
    main()
