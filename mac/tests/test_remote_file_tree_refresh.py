"""Exercise remote tree refresh, scheduling, and the production SSH transport.

Run: python3 mac/tests/test_remote_file_tree_refresh.py
No app build, SSH server, personal SSH configuration, or credentials are needed.
All binaries, module caches, and filesystem fixtures are removed after the test.
"""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="zshell-remote-tree-tests-") as directory:
        temporary = Path(directory)
        support = temporary / "Support.swift"
        support.write_text("""import Foundation
nonisolated struct RemoteHost: Codable, Equatable, Sendable {}
""")
        ssh = temporary / "fixture-ssh"
        ssh.write_text("""#!/bin/sh
for argument do command="$argument"; done
printf '%s\\n' request >> "$ZSHELL_TREE_REQUEST_LOG"
if [ -e "$ZSHELL_TREE_FAILURE_FILE" ]; then
    printf 'fixture transport failure\\n' >&2
    exit 255
fi
exec /bin/sh -c "$command"
""")
        ssh.chmod(0o700)
        configuration = temporary / "ssh_config"
        configuration.write_text("Host fixture.invalid\n    HostName fixture.invalid\n")
        environment = dict(os.environ)
        environment.update({
            "ZSHELL_SSH_CONFIG_FILE": str(configuration),
            "ZSHELL_SSH_AGENT_RESOLVED": "1",
            "ZSHELL_TREE_REQUEST_LOG": str(temporary / "requests"),
            "ZSHELL_TREE_FAILURE_FILE": str(temporary / "fail"),
        })
        environment.pop("SSH_AUTH_SOCK", None)
        binary = temporary / "remote-tree-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-warnings-as-errors", "-O",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/FileTreeModel.swift"),
            str(ROOT / "mac/zshell/RemoteSSH.swift"),
            str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
            str(ROOT / "mac/zshell/RemoteFileService.swift"),
            str(ROOT / "mac/zshell/FileSaveCoordinator.swift"),
            str(ROOT / "mac/zshell/AppWindowPresentation.swift"),
            str(support), str(ROOT / "mac/tests/RemoteFileTreeRefreshTests.swift"),
            "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        subprocess.run([str(binary), str(temporary), str(ssh)], cwd=ROOT,
                       env=environment, check=True, timeout=60)


if __name__ == "__main__":
    main()
