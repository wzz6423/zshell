"""Exercise production template codec, validation, path resolution and library I/O.

This lightweight probe needs no app build or live terminal. All build artifacts
and template libraries live in a disposable directory. Real AppKit/PTY checks are
covered separately by test_workspace_template_surfaces.py.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "mac/zshell"

with tempfile.TemporaryDirectory(prefix="zshell-workspace-template-probe-", dir="/tmp") as directory:
    temporary = Path(directory)
    snapshot = (SOURCE / "SessionStore.swift").read_text()
    pane = snapshot[snapshot.index("        enum PaneContentSnapshot:"):snapshot.index("        struct ColumnSnapshot:")]
    layout = snapshot[snapshot.index("        indirect enum LayoutSnapshot:"):snapshot.index("        /// One tab's recursive layout")]
    persistent = (SOURCE / "PersistentCLIConnection.swift").read_text()
    private_io = persistent[persistent.index("    static func readPrivate("):persistent.rindex("\n}")]
    settings_file = (SOURCE / "SettingsConfigFile.swift").read_text()
    settings_file = settings_file[:settings_file.index("/// File descriptors and debounce")]
    wire = (SOURCE / "PTYMux.swift").read_text()
    wire_source = wire[wire.index("nonisolated enum PTYMuxError:"):wire.index("enum PTYMuxPaths {")]
    wire_source += wire[wire.index("private extension Data {"):wire.index("private final class PTYMuxDaemon")]
    panes = (SOURCE / "Panes.swift").read_text()
    axis = panes[panes.index("enum PaneSplitAxis:"):panes.index("/// One tile in a tab")]
    dependencies = temporary / "Dependencies.swift"
    dependencies.write_text(
        "import AppKit\nimport Darwin\nimport Foundation\n"
        "struct EditorState: Codable {}\n"
        "struct AgentConversationIdentity: Codable { var sessionID: String }\n"
        "struct SessionWorktree: Codable { var path: String }\n"
        "struct CLIError: Error { static func message(_ value: String) -> CLIError { CLIError() } }\n"
        "nonisolated enum PTYMuxConstants { static let maximumFrameBytes = 1_048_576; static let socketTimeout: TimeInterval = 2 }\n"
        + axis + "struct SessionSnapshot { struct ProjectSnapshot {\n" + pane + layout + "} }\n"
        "@MainActor enum AppSettings { static var configURL: URL { URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(\"config.toml\") } }\n"
        "struct PersistentCLIConnection {\n" + private_io + "}\n"
        + wire_source + settings_file
    )
    binary = temporary / "template-tests"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-module-cache-path", str(temporary / "ModuleCache"),
        str(dependencies), str(SOURCE / "WorkspaceTemplate.swift"),
        str(SOURCE / "WorkspaceTemplateStore.swift"), str(SOURCE / "TerminalStartupCommand.swift"),
        str(ROOT / "mac/tests/WorkspaceTemplateTests.swift"), "-o", str(binary),
    ], cwd=ROOT, check=True)
    subprocess.run([str(binary), str(temporary / "files")], cwd=ROOT, check=True, timeout=30)
