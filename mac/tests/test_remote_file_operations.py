"""Run remote file operations through the production SSH command transport.

The SSH executable is replaced by a local shell, with no server, credentials,
GUI, or personal configuration. All binaries and fixtures are temporary.
A project root reached through a directory symlink must be readable, while a
symlink inside that project must not be followed.
"""

import os
from pathlib import Path
import platform
import subprocess
import tempfile


# Inserted into the production driver. The fixture path stays under unresolved
# /tmp, which is a symlink on macOS, and the project directory is itself a
# relative symlink. Inner links must still fail closed.
SYMLINK_ROOT_CHECKS = r"""        try require(CommandLine.arguments.count == 14, "Symlink project fixture is passed to the driver")
        let symlinkRoot = CommandLine.arguments[7]
        let symlinkFile = CommandLine.arguments[8]
        let directRoot = CommandLine.arguments[9]
        let directFile = CommandLine.arguments[10]
        let escapePath = CommandLine.arguments[11]
        let aliasPath = CommandLine.arguments[12]
        let outsidePath = CommandLine.arguments[13]
        let symlinkSource = RemoteFileSource(endpoint: source.endpoint, root: symlinkRoot)
        let directSource = RemoteFileSource(endpoint: source.endpoint, root: directRoot)
        let symlinkListing = try service.transport.listDirectory(endpoint: source.endpoint, directory: symlinkRoot)
        try require(symlinkListing.contains(where: { $0.name == "note.txt" && !$0.isDirectory }), "A directory-symlink project root can be listed")
        let symlinkRead = try service.read(source: symlinkSource, path: symlinkFile)
        try require(symlinkRead.text == "through-symlink\n" && symlinkRead.isRegular && symlinkRead.root == symlinkRoot,
                    "A regular file in a symlinked project root can be read")
        let directRead = try service.read(source: directSource, path: directFile)
        try require(directRead.text == "through-symlink\n" && directRead.isRegular && directRead.root == directRoot
                    && directRead.rootIdentity == symlinkRead.rootIdentity,
                    "A project path that crosses /tmp opens the same real directory")
        guard case .saved(let symlinkSaved) = try service.save(source: symlinkSource, path: symlinkFile, text: "saved-through-symlink\n", baseline: symlinkRead) else {
            fatalError("Saving through a symlinked project root conflicted")
        }
        try require(symlinkSaved.text == "saved-through-symlink\n", "Saving through a symlinked project root returns the written bytes")
        try require(try String(contentsOfFile: directFile, encoding: .utf8) == "saved-through-symlink\n", "The write lands in the real directory")
        try require(try service.read(source: directSource, path: directFile).text == "saved-through-symlink\n",
                    "The written file can be read through the /tmp path")
        try rejects(.unsafePath) { _ = try service.read(source: symlinkSource, path: escapePath) }
        try rejects(.unsafePath) { _ = try service.create(source: symlinkSource, directory: symlinkRoot + "/escape", name: "intrusion.txt", isDirectory: false) }
        let aliasRead = try service.read(source: symlinkSource, path: aliasPath)
        try require(!aliasRead.isRegular && aliasRead.data == nil, "A symlink file inside the project is not read")
        try rejects(.unsafePath) { _ = try service.save(source: symlinkSource, path: aliasPath, text: "unsafe", baseline: aliasRead) }
        let outsideFile = URL(fileURLWithPath: outsidePath)
        try require(try String(contentsOf: outsideFile, encoding: .utf8) == "outside\n", "Rejected inner symlinks leave the outside file unchanged")
        try require(!fm.fileExists(atPath: (symlinkRoot as NSString).deletingLastPathComponent + "/intrusion.txt"),
                    "A symlink directory inside the project cannot create an outside file")
"""


ROOT = Path(__file__).resolve().parents[2]


def symlink_project_fixture(unresolved_root):
    """Build a project whose path crosses /tmp and whose root is a directory symlink.

    The returned paths stay unresolved. Resolving them here would hide the bug.
    """
    linked = unresolved_root / "linked-project"
    real = linked / "real"
    real.mkdir(parents=True)
    (real / "note.txt").write_text("through-symlink\n", encoding="utf-8")
    project = linked / "project"
    project.symlink_to("real", target_is_directory=True)
    outside = linked / "outside.txt"
    outside.write_text("outside\n", encoding="utf-8")
    (real / "escape").symlink_to(linked, target_is_directory=True)
    (real / "alias.txt").symlink_to(outside)
    symlink_root = str(project)
    direct_root = str(real)
    if os.readlink(project) != "real" or not symlink_root.startswith("/tmp/") or not direct_root.startswith("/tmp/"):
        raise SystemExit("project fixture must stay on the unresolved /tmp path")
    if not os.path.islink("/tmp") or not project.is_symlink() or real.is_symlink():
        raise SystemExit("expected a directory symlink project root under /tmp")
    return [
        symlink_root,
        str(project / "note.txt"),
        direct_root,
        str(real / "note.txt"),
        str(project / "escape" / "outside.txt"),
        str(project / "alias.txt"),
        str(outside),
    ]


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
        driver = temporary / "RemoteFileDriver.swift"
        anchor = r'        print("Remote file operations: \(checks) checks passed; no GUI, server, network, credentials, or retained binary")'
        production = (ROOT / "mac/tests/RemoteFileServiceTests.swift").read_text()
        if production.count(anchor) != 1:
            raise SystemExit("remote file driver has no unique insertion point for the symlink root case")
        driver.write_text(production.replace(anchor, SYMLINK_ROOT_CHECKS + anchor, 1))
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
            "-warnings-as-errors", "-O", "-target", f"{platform.machine()}-apple-macos15.6",
            "-module-cache-path", str(temporary / "ModuleCache"),
            str(ROOT / "mac/zshell/RemoteSSH.swift"), str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
            str(ROOT / "mac/zshell/FileSaveCoordinator.swift"), str(ROOT / "mac/zshell/RemoteFileService.swift"),
            str(support), str(driver), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        symlink_args = symlink_project_fixture(Path(directory))
        with tempfile.TemporaryDirectory(prefix=".zshell-remote-file-test-", dir=Path.home()) as named_home:
            subprocess.run([str(binary), str(temporary), str(ssh), str(missing), str(limited), named_home, str(invalid), *symlink_args],
                           cwd=ROOT, env=environment, check=True, timeout=90)


if __name__ == "__main__":
    main()
