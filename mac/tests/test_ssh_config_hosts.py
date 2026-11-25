"""Compile the production SSH config reader with isolated OpenSSH fixtures."""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="zshell-ssh-config-tests-", dir="/tmp") as directory:
        temporary = Path(directory)
        support = temporary / "Support.swift"
        support.write_text("import Foundation\nnonisolated struct RemoteHost: Codable, Equatable, Sendable {}\n")
        binary = temporary / "ssh-config-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor", "-warnings-as-errors", "-O",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/RemoteSSH.swift"),
            str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
            str(ROOT / "mac/zshell/SSHConfigHosts.swift"),
            str(support), str(ROOT / "mac/tests/SSHConfigHostsTests.swift"),
            "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        home = temporary / "runner-home"
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home)})
        subprocess.run([str(binary), str(temporary)], cwd=ROOT, env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
