"""Check command-task integration survives adopting the daemon's existing PTY.

Run: python3 mac/tests/test_persistent_command_tasks.py [--source <TerminalSession.swift>]
The fixture runs the production launch-artifact adoption branch without a renderer.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=ROOT / "mac/zshell/TerminalSession.swift")
args = parser.parse_args()
source = args.source.read_text()
adoption = source[source.index("        let artifacts = existingPTY.map {"):
                  source.index("        let script = Self.makeLaunchScript(")]
support = source[source.index("        supportsCommandTaskShellIntegration ="):
                 source.index("        title =", source.index("        supportsCommandTaskShellIntegration ="))]
fixture = r'''
import Foundation
struct ExistingPTY { let launchDirectoryURL: URL? }
struct LaunchArtifacts {
    let directoryURL: URL?
    let pidFileURL: URL?
    let replayFileURL: URL?
    let shellIntegrationDirectoryURL: URL?
}
struct Adoption {
    static var freshLaunches = 0
    static func makeLaunchArtifacts(restoredHistory: String?, backend: Int, shellPath: String?, persistentSessionID: UUID?) -> LaunchArtifacts {
        freshLaunches += 1
        return LaunchArtifacts(directoryURL: nil, pidFileURL: nil, replayFileURL: nil, shellIntegrationDirectoryURL: nil)
    }
    static func supports(_ root: URL?, directCommand: [String]? = nil) -> Bool {
        let existingPTY: ExistingPTY? = ExistingPTY(launchDirectoryURL: root)
        let restoredHistory: String? = nil
        let backend = 0
        let shellPath = "/bin/zsh"
        let preserve = true
        let sessionID = UUID()
        let supportsCommandTaskShellIntegration: Bool
'''
fixture += adoption + support + r'''
        precondition(artifacts.directoryURL == root)
        return supportsCommandTaskShellIntegration
    }
}
@main struct Probe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let integration = root.appendingPathComponent("zsh-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true)
        let marker = integration.appendingPathComponent(".zshrc")
        try Data("existing shell integration".utf8).write(to: marker)
        let results: [(String, Bool)] = [
            ("adopted zsh retains command-task support", Adoption.supports(root)),
            ("direct-command sessions stay unsupported", !Adoption.supports(root, directCommand: ["/bin/true"])),
            ("missing launch directory stays unsupported", !Adoption.supports(nil)),
            ("adoption does not start a new shell", Adoption.freshLaunches == 0),
            ("adoption preserves the shell's existing artifacts", try String(contentsOf: marker, encoding: .utf8) == "existing shell integration"),
        ]
        try FileManager.default.removeItem(at: integration)
        let missingIsUnsupported = !Adoption.supports(root)
        var failures = 0
        for (name, passed) in results + [("shells without retained integration stay unsupported", missingIsUnsupported)] {
            print("\(passed ? "PASS" : "FAIL") \(name)")
            if !passed { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="zshell-persistent-command-test-", dir="/tmp") as directory:
    temp = Path(directory)
    helper = temp / "Probe.swift"
    helper.write_text(fixture)
    binary = temp / "probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(helper), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temp / "launch")], check=True)
