"""Delay the production completion-time PID query while the next TUI starts.

python3 -B mac/tests/test_terminal_history_refresh.py
python3 -B mac/tests/test_terminal_history_refresh.py --source-ref 0d9980b
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]

SUPPORT = r'''
import AppKit
import Darwin
import Foundation

@MainActor protocol TerminalBackendSurface {
    func exportScreenFile() -> String?
    func exportScrollbackFile() -> String?
}

@MainActor final class RefreshSurface: TerminalBackendSurface {
    var foregroundPid: pid_t? = 4242
    var screen = "COMPLETED_SHELL_OUTPUT"
    func exportScrollbackFile() -> String? { nil }
    func exportScreenFile() -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("screen")
        try! Data(screen.utf8).write(to: file)
        return file.path
    }
}

@MainActor final class AppSettings {
    static let shared = AppSettings()
    var restoreTerminalHistory = true
}

@MainActor struct RefreshLifecycle {
    enum Phase { case idle, executing }
    var completionSequence: UInt64 = 1
    var phase: Phase = .idle
}

nonisolated final class PersistentPTY: @unchecked Sendable {
    let queried = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result: pid_t?
    init(result: pid_t?) { self.result = result }
    func fetchForegroundPID() -> pid_t? {
        queried.signal()
        released.wait()
        defer { finished.signal() }
        return result
    }
    func waitForQuery() { precondition(queried.wait(timeout: .now() + 1) == .success) }
}

@MainActor final class RefreshSession {
    var remoteConnection: Int? = nil
    var persistentPTY: PersistentPTY?
    let surface = RefreshSurface()
    var commandLifecycle = RefreshLifecycle()
    var hasExited = false
    var isTerminating = false
    var shellPid: pid_t? = 4242
    static let persistedHistoryLineLimit = 500
    var lastHistorySnapshot: String? = "PREVIOUS_HISTORY"
    init(pid: pid_t?) { persistentPTY = PersistentPTY(result: pid) }
    func startRefresh() { refreshHistoryAfterCommandFinished() }
'''

PROBE = r'''
}

@main @MainActor struct RefreshProbe {
    static func main() async {
        for scenario in ["late-screen", "failed-query", "superseded", "executing", "disabled", "terminated"] {
            AppSettings.shared.restoreTerminalHistory = true
            let session = RefreshSession(pid: scenario == "failed-query" ? nil : 4242)
            let pty = session.persistentPTY!
            session.startRefresh()
            pty.waitForQuery()
            session.surface.screen = "NEXT_COMMAND_TUI"
            if scenario == "superseded" { session.commandLifecycle.completionSequence += 1 }
            if scenario == "executing" { session.commandLifecycle.phase = .executing }
            if scenario == "disabled" { AppSettings.shared.restoreTerminalHistory = false }
            if scenario == "terminated" { session.isTerminating = true }
            pty.released.signal()
            try? await Task.sleep(for: .milliseconds(50))
            let expected = scenario == "late-screen" ? "COMPLETED_SHELL_OUTPUT" : "PREVIOUS_HISTORY"
            guard session.lastHistorySnapshot == expected else {
                fputs("FAIL \(scenario): expected \(expected), got \(session.lastHistorySnapshot ?? "nil")\n", stderr)
                exit(1)
            }
            print("PASS \(scenario): \(expected)")
        }
        print("Terminal history refresh: 6 scenarios passed")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref")
    options = parser.parse_args()

    def source(name):
        path = f"mac/zshell/{name}"
        if options.source_ref:
            return subprocess.check_output(["git", "show", f"{options.source_ref}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    session = source("TerminalSession.swift")
    start = session.index("    private func refreshHistoryAfterCommandFinished() {")
    end = session.index("    var shellName: String {", start)
    with tempfile.TemporaryDirectory(prefix="zshell-history-refresh-") as directory:
        temporary = Path(directory)
        history = temporary / "TerminalHistory.swift"
        history.write_text(source("TerminalHistory.swift"))
        probe = temporary / "Refresh.swift"
        probe.write_text(SUPPORT + session[start:end] + PROBE)
        binary = temporary / "history-refresh"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
            "-warnings-as-errors", "-module-cache-path", str(temporary / "modules"),
            str(history), str(probe), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=90)
        subprocess.run([str(binary)], cwd=ROOT, check=True, timeout=10)


if __name__ == "__main__":
    main()
