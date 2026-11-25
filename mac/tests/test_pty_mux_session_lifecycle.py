"""Exercise production PTY lifecycle code with real shells and background jobs.

The standalone probe replaces only the renderer mirror; PTYs, process identity,
signals, attachment queues, and session eviction use production Swift code.
--source-ref verifies the regression against an earlier lifecycle implementation.
--built-app links the same checks against a Debug module and real terminal mirror.
All binaries, module caches, process fixtures, and private mux state are disposable.
"""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_file_tree_background import built_app_arguments, compiler_arguments


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-ref")
parser.add_argument("--built-app", type=Path)
parser.add_argument("--case", choices=("exited", "terminate", "detach", "fork", "fork-live", "recreate", "identity", "stress",
                                     "local-terminate", "local-fork", "local-fork-exit", "local-exited", "local-identity"), action="append")
options = parser.parse_args()
if options.source_ref and options.built_app:
    raise SystemExit("Choose a historical source probe or an existing Debug app")
cases = options.case or ("exited", "terminate", "detach", "fork", "fork-live", "recreate")
if not options.source_ref and options.case is None:
    cases += ("identity", "stress")
    if not options.built_app:
        cases += ("local-terminate", "local-fork", "local-fork-exit", "local-exited", "local-identity")
if options.source_ref and any(case in ("identity", "stress") for case in cases):
    raise SystemExit("Earlier lifecycle implementations do not provide the process identity guard")
if options.source_ref and "local-identity" in cases:
    raise SystemExit("Earlier local teardown implementations do not provide the process identity snapshot")

with tempfile.TemporaryDirectory(prefix="zshell-pty-lifecycle-", dir="/tmp") as directory:
    temporary = Path(directory)
    protocol = (ROOT / "mac/zshell/ZshellAutomationProtocol.swift").read_text()
    identity = (ROOT / "mac/zshell/AgentStatusReporting.swift").read_text()
    support = temporary / "Support.swift"
    support.write_text(protocol[:protocol.index("struct ZshellAutomationRequest")]
                       + identity[identity.index("struct ZshellAgentProcessIdentity"):identity.index("struct ZshellAgentReport")]
                       + """
enum CLIError: Error { case message(String) }
struct ZshellTheme { var foreground: UInt32 = 0; var background: UInt32 = 0; var cursor: UInt32 = 0 }
final class PersistentTerminalState {
    init(columns: UInt16, rows: UInt16, theme: ZshellTheme) throws {}
    func feed(_ bytes: Data, answerQueries: Bool) -> Data { Data() }
    func snapshot() throws -> Data { Data() }
    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {}
    func setTheme(_ theme: ZshellTheme) {}
}
""")
    sources = [ROOT / "mac/zshell" / name for name in (
        "PTYMux.swift", "PTYMuxSession.swift", "PTYMuxSessionStore.swift", "PTYMuxObserverFrame.swift",
        "PersistentCLIConnection.swift", "ProcessWorkingDirectory.swift", "TerminalBashShellIntegration.swift",
    )]
    if options.source_ref:
        previous = temporary / "PTYMuxSession.swift"
        previous.write_bytes(subprocess.check_output(
            ["git", "show", f"{options.source_ref}:mac/zshell/PTYMuxSession.swift"], cwd=ROOT))
        sources[sources.index(ROOT / "mac/zshell/PTYMuxSession.swift")] = previous
    local_cases = any(case.startswith("local-") for case in cases)
    if local_cases:
        if options.built_app:
            raise SystemExit("Local teardown source probes run without --built-app; use the surface integration fixture for a Debug app")
        terminal = subprocess.check_output(
            ["git", "show", f"{options.source_ref}:mac/zshell/TerminalSession.swift"], cwd=ROOT).decode() \
            if options.source_ref else (ROOT / "mac/zshell/TerminalSession.swift").read_text()
        # Keep the production close path intact; unrelated UI collaborators are
        # inert so the fixture can own and reap its PTY without a renderer.
        teardown = terminal[terminal.index("    private func beginTeardown("):
                            terminal.index("    private func removeLaunchArtifacts(")]
        teardown = re.sub(r"^        (?:cancelPromptQueueDispatch\(\)|promptQueueBar\..*|AgentAutomationMonitor\..*|"
                          r"TerminalNotificationService\..*|terminalProfileObservation =.*|promptQueueSettingsObservation =.*|"
                          r"surface\.splitTarget\..*|cancelClipboardPaste\(\)|recordAgentConversation\(.*|"
                          r"AgentTurnReviewStore\..*|TerminalCommandTaskStore\..*|surface\.onBecomeFirstResponder =.*)\n",
                          "", teardown, flags=re.MULTILINE)
        teardown = teardown.replace("    private func beginTeardown(", "    func beginTeardown(")
        local_support = temporary / "TerminalSession.swift"
        local_support.write_text("""import Darwin
import Foundation
@MainActor final class TerminalSession {
    final class Surface {
        var foregroundPid: pid_t?
        var onDetach: (() -> Void)?
        func setSurfaceVisible(_ value: Bool) {}
        func detach() { onDetach?() }
    }
    let surface = Surface()
    var shellPid: pid_t?
    var persistentPTY: Int?
    var teardownTask: Task<Void, Never>?
    var hasExited = false
    var onExited: ((TerminalSession) -> Void)?
    init(pid: pid_t, foreground: pid_t?) {
        shellPid = pid
        surface.foregroundPid = foreground
    }
    func clearAutomationAgentStatus() {}
    func removeLaunchArtifacts() {}
""" + teardown + "}\n")
        sources.append(local_support)
    binary = temporary / "lifecycle-tests"
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "PTY_MUX_STANDALONE",
        "-target", f"{platform.machine()}-apple-macos15.6", "-module-cache-path", str(temporary / "ModuleCache"),
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-warnings-as-errors",
        str(support), *map(str, sources), str(ROOT / "mac/tests/PTYMuxSessionLifecycleTests.swift"), "-o", str(binary),
    ]
    if options.built_app:
        command = compiler_arguments(temporary) + built_app_arguments(options.built_app.resolve())
        command += [str(ROOT / "mac/tests/PTYMuxSessionLifecycleTests.swift"), "-o", str(binary)]
    if not options.source_ref:
        command += ["-D", "PTY_MUX_IDENTITY_TEST"]
    if local_cases:
        command += ["-D", "TERMINAL_SESSION_TEARDOWN_TEST"]
        if "struct PTYSessionProcesses" in (ROOT / "mac/zshell/PTYMuxSession.swift").read_text() and not options.source_ref:
            command += ["-D", "PTY_SESSION_PROCESS_TEST"]
    subprocess.run(command, cwd=ROOT, check=True, timeout=120)
    for case in cases:
        home = temporary / case
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ZSHELL_")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           ZSHELL_PTY_MUX_DIRECTORY=str(home / "mux"))
        subprocess.run([str(binary), case, str(home)], cwd=ROOT, env=environment, check=True, timeout=30)
