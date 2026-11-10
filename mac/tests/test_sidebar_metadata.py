"""Exercise sidebar metadata batching and cancellation with controllable runners.

The scheduler, request invalidation and branch parser are production source;
fixture Git/SSH runners control blocking without network access or user files.
All compiled output is removed after the test.
"""

from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "mac/zshell/AppKitProjectSidebarView.swift").read_text()
metadata = source[source.index("@MainActor\nprivate final class ProjectSidebarMetadata"):]
metadata = metadata.replace(
    "GitCommandRunner.runData(arguments, in: root, limit: 4_096, timeout: min(2, remaining))",
    "FixtureGitRunner.runData(arguments, in: root, limit: 4_096, timeout: min(2, remaining))",
).replace(
    "OpenSSHTransport(timeout: 3, outputLimit: 4_096)",
    "FixtureSSHTransport(timeout: 3, outputLimit: 4_096)",
)
model = (ROOT / "mac/zshell/GitStatusModel.swift").read_text()
start = model.index("    nonisolated struct BranchSnapshot:")
branch = model[start:model.index("\n}\n", start)]
branch += model[model.index("    private nonisolated static func containsGitMetadata"):
                model.index("    private nonisolated static func gitFailureMessage")]
shared = (ROOT / "mac/zshell/RemoteHost.swift").read_text().split("nonisolated struct RemoteSessionInfo:")[0]
fixture = (ROOT / "mac/tests/SidebarMetadataTests.swift").read_text()
fixture += "\nnonisolated struct GitStatusModel {\n" + branch + "\n}\n"
fixture += r'''
nonisolated enum FixtureGitRunner {
    static func runData(_ arguments: [String], in directory: String, limit: Int, timeout: TimeInterval) -> GitCommandDataResult {
        precondition(limit == 4_096 && timeout <= 2 && timeout > 0)
        let status: Int32
        let value: String
        switch arguments.first {
        case "rev-parse":
            status = 0
            if arguments.contains("--show-toplevel") {
                _ = MetadataFixtureState.shared.probe(directory)
                value = directory + "\n"
            } else { value = directory + "/.git\n" + directory + "/.git\n" }
        case "symbolic-ref":
            status = 0
            value = "branch-" + (directory as NSString).lastPathComponent + "\n"
        case "config": status = 1; value = ""
        default: status = -1; value = ""
        }
        return GitCommandDataResult(status: status, stdout: Data(value.utf8), stderr: "", truncated: false)
    }
}
nonisolated struct FixtureSSHTransport {
    var timeout: TimeInterval
    var outputLimit: Int
    func run(endpoint: SSHEndpoint, command: [String], authentication: SSHAuthentication, credentialID: UUID?) throws -> BoundedProcessOutput {
        precondition(timeout == 3 && outputLimit == 4_096)
        precondition(command.count == 7 && command == ["/usr/bin/git", "-C", command[2], "symbolic-ref", "--quiet", "--short", "HEAD"])
        return BoundedProcessOutput(stdout: MetadataFixtureState.shared.probe("ssh:" + command[2])! + "\n",
                                    stderr: "", wasTruncated: false)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="zshell-sidebar-metadata-", dir="/tmp") as directory:
    temporary = Path(directory)
    support = temporary / "Support.swift"
    support.write_text(fixture + "\n" + metadata + "\n" + shared)
    binary = temporary / "metadata-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
        "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-enable-upcoming-feature", "InferIsolatedConformances", "-warnings-as-errors",
        "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(temporary / "modules"),
        str(support), str(ROOT / "mac/zshell/RemoteSSH.swift"), str(ROOT / "mac/zshell/SSHAgentEnvironment.swift"),
        str(ROOT / "mac/zshell/GitCommandRunner.swift"), str(ROOT / "mac/zshell/GitProxy.swift"), "-o", str(binary),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary)], check=True, cwd=ROOT, timeout=35)
