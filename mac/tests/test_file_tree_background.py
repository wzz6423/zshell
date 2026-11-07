"""Exercise the production file tree's background refresh with real directories.

Needs macOS and Xcode's Swift compiler; no app build or SSH server is required.
The binary, module cache, support stubs, and filesystem fixtures are temporary.
"""

from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

SUPPORT = """import AppKit
import Darwin
import Foundation

nonisolated struct SSHEndpoint: Equatable, Sendable {
    let destination: String
    struct DirectoryEntry: Equatable, Sendable {
        let name: String
        let isDirectory: Bool
    }
}

nonisolated struct OpenSSHTransport {
    func listDirectory(endpoint: SSHEndpoint, directory: String) throws -> [SSHEndpoint.DirectoryEntry] {
        return [.init(name: "remote-file.txt", isDirectory: false)]
    }
}

@MainActor enum AppWindowPresentation {
    static func hostWindow() -> NSWindow? { nil }
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="zshell-file-tree-tests-") as directory:
        temporary = Path(directory)
        support = temporary / "Support.swift"
        support.write_text(SUPPORT)
        binary = temporary / "file-tree-tests"
        command = [
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-warnings-as-errors", "-O",
            "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/FileTreeModel.swift"), str(support),
            str(ROOT / "mac/tests/FileTreeBackgroundTests.swift"), "-o", str(binary),
        ]
        subprocess.run(command, cwd=ROOT, check=True, timeout=120)
        subprocess.run([str(binary), str(temporary / "fixture")], cwd=ROOT, check=True, timeout=90)


if __name__ == "__main__":
    main()
