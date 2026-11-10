"""Exercise the production file tree's background refresh with real directories.

Needs macOS and Xcode's Swift compiler; no app build or SSH server is required.
The binary, module cache, support stubs, and filesystem fixtures are temporary.

Use --built-app '/path/to/zshell Debug.app' to run the same creation safety
checks against an existing Debug app's compiled module without rebuilding it.
"""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

SUPPORT = """import AppKit
import Darwin
import Foundation

nonisolated struct SSHEndpoint: Equatable, Sendable {
    let host: String
    var destination: String { host }
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


def compiler_arguments(temporary):
    return [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor",
        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-warnings-as-errors", "-O",
        "-target", f"{platform.machine()}-apple-macos15.6",
        "-module-cache-path", str(temporary / "ModuleCache"),
    ]


def built_app_arguments(application):
    products = application.parent
    build = products.parent.parent
    library = application / "Contents/MacOS/zshell.debug.dylib"
    if not library.is_file() or not (products / "zshell.swiftmodule").is_dir():
        raise SystemExit("--built-app requires an existing Debug app and adjacent zshell.swiftmodule")
    arguments = ["-D", "ZSHELL_FILE_TREE_BUILT_APP", "-I", str(products),
                 "-I", str(products / "include"), "-F", str(products)]
    for modulemap in sorted((build / "Intermediates.noindex/GeneratedModuleMaps").glob("*.modulemap")):
        arguments += ["-Xcc", f"-fmodule-map-file={modulemap}"]
    for include in ("STTextView/Sources/STObjCLandShim/include", "swift-cmark/src/include",
                    "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"):
        path = ROOT / "mac/Vendor" / include
        arguments += ["-I", str(path), "-Xcc", f"-fmodule-map-file={path / 'module.modulemap'}"]
    return arguments + ["-I", str(ROOT / "mac/Vendor/alacritty-bridge/include"),
                        "-I", str(ROOT / "mac/Vendor/tree-sitter/lib/include"), str(library),
                        "-Xlinker", "-rpath", "-Xlinker", str(products),
                        "-Xlinker", "-rpath", "-Xlinker", str(library.parent)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--built-app", type=Path)
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zshell-file-tree-tests-") as directory:
        temporary = Path(directory)
        binary = temporary / "file-tree-tests"
        command = compiler_arguments(temporary)
        if options.built_app:
            command += built_app_arguments(options.built_app.resolve())
        else:
            support = temporary / "Support.swift"
            support.write_text(SUPPORT)
            command += [str(ROOT / "mac/zshell/FileTreeModel.swift"), str(support)]
        command += [str(ROOT / "mac/tests/FileTreeBackgroundTests.swift"), "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True, timeout=120)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        if options.built_app:
            home = temporary / "home"
            home.mkdir()
            environment["CFFIXED_USER_HOME"] = str(home)
        subprocess.run([str(binary), str(temporary / "fixture")], cwd=ROOT,
                       env=environment, check=True, timeout=90)


if __name__ == "__main__":
    main()
