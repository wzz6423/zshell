import AppKit
import Darwin
@testable import zshell

@MainActor private final class ProcessTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private func pumpProcesses(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

@main struct SessionProcessSurfaceTests {
    @MainActor static func main() {
        if RemoteSessionRelay.shouldRun { RemoteSessionRelay.run() }
        do { try run() }
        catch { fputs("Session process surface failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let arguments = CommandLine.arguments
        let backend = arguments[1]
        let executable = arguments[2]
        AppSettings.shared.terminalBackend = backend == "ghostty" ? .libghostty : .alacritty
        AppSettings.shared.terminalStartupProgram = ""
        AppSettings.shared.preserveTerminalSessions = false
        AppSettings.shared.restoreTerminalHistory = false
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var windows: [NSWindow] = []
        var terminals: [TerminalSession] = []
        var remoteCleanup: (() -> Void)?
        var checks = 0

        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "SessionProcessSurface", code: 2, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
            print("PASS \(backend) processes: \(label)")
        }
        func wait(_ label: String, timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                pumpProcesses(0.05)
            }
            throw NSError(domain: "SessionProcessSurface", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
        func mount(_ session: TerminalSession) {
            let surface = session.surface
            surface.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
            let window = ProcessTestWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            window.makeFirstResponder(surface)
            surface.setSurfaceVisible(true)
            windows.append(window)
            terminals.append(session)
        }
        func panel(_ model: SessionInfoModel, session: TerminalSession, remoteProject: Project?) -> SessionInfoPanelView {
            let view = SessionInfoPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
            let window = ProcessTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            windows.append(window)
            view.configure(model: model, session: session, remoteProject: remoteProject,
                           editor: .systemDefault, showsVimHints: false, fontScale: 1)
            view.layoutSubtreeIfNeeded()
            return view
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        func row(in view: NSView, for process: SessionInfoModel.ProcessItem) -> NSView? {
            descendants(view).first { $0.accessibilityLabel() == "\(process.name), pid \(process.pid)" }
        }
        func texts(in view: NSView) -> [String] {
            descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        func sleeper(_ model: SessionInfoModel) -> SessionInfoModel.ProcessItem? {
            model.processes.first { $0.name == "sleep" }
        }

        defer {
            terminals.forEach { $0.terminate() }
            pumpProcesses(0.3)
            remoteCleanup?()
            windows.forEach { $0.contentView = nil }
        }

        let local = TerminalSession(initialDirectory: home, commandArguments: ["/bin/sh", "-i"])
        mount(local)
        try wait("local terminal did not launch") { local.shellPid != nil }
        local.sendCommand("sleep 45\r")
        let localModel = SessionInfoModel()
        try wait("local sleep did not appear under the shell") {
            localModel.sync(root: home, projectRoot: home, projectRootSource: .shell,
                            shellName: "sh", shellPid: local.shellPid)
            return sleeper(localModel) != nil
        }
        try check(localModel.remoteSource == nil && localModel.remoteError == nil, "a local pane samples its own shell")
        let localPanel = panel(localModel, session: local, remoteProject: nil)
        let localRow = row(in: localPanel, for: sleeper(localModel)!)
        try check(localRow != nil, "the local sleep row is rendered")
        try check(localRow?.menu?.items.map(\.title).contains(String(localized: "Terminate")) == true,
                  "local rows keep their Terminate action")

        let manager = TerminalManager()
        let unreachable = try RemoteHost(name: "Unreachable", address: "tailscale://127.0.0.1:1")
        let unreachableProject = manager.sharedProject(host: unreachable, directory: "/srv/project")
        let unreachableModel = SessionInfoModel()
        unreachableModel.sync(root: "", projectRoot: "", projectRootSource: .shell, shellName: "", shellPid: nil,
                              remote: .init(host: unreachable, directory: "/srv/project", sessionID: UUID()))
        try wait("an unreachable host did not report an error") { unreachableModel.remoteError != nil }
        try check(unreachableModel.processes.isEmpty, "an unreachable host lists no processes")
        let errorPanel = panel(unreachableModel, session: local, remoteProject: unreachableProject)
        try check(texts(in: errorPanel).contains(unreachableModel.remoteError!), "the remote error is shown in the panel")

        guard arguments.count > 5 else {
            print("PASS \(backend) processes: \(checks) checks (remote host not configured)")
            return
        }
        let host = try RemoteHost(name: "Process SSH fixture", address: arguments[3], serverPath: arguments[5])
        let directory = arguments[4]
        let project = manager.sharedProject(host: host, directory: directory)
        let id = UUID()
        remoteCleanup = { try? RemoteHostClient.terminate(host: host, directory: directory, sessionID: id) }
        let connection = try RemoteSessionConnection(host: host, directory: directory, sessionID: id,
            createIfMissing: true, command: ["/bin/sh", "-i"], launchSettings: TerminalLaunchSettings())
        let remote = TerminalSession(initialDirectory: home,
            commandArguments: [executable, RemoteSessionRelay.argument, connection.configurationURL.path],
            remoteConnection: connection)
        mount(remote)
        try wait("remote terminal did not connect", timeout: 30) { remote.remoteStatus?.state == .connected }
        remote.sendCommand("sleep 45\r")
        let remoteModel = SessionInfoModel()
        let source = SessionInfoModel.RemoteSource(host: host, directory: directory, sessionID: id)
        try wait("remote sleep did not appear", timeout: 30) {
            remoteModel.sync(root: "", projectRoot: "", projectRootSource: .shell, shellName: "", shellPid: nil, remote: source)
            return sleeper(remoteModel) != nil
        }
        let remoteSleep = sleeper(remoteModel)!
        try check(remoteModel.remoteError == nil && remoteSleep.pid > 1, "the host reports the session's sleep")
        try check(remoteModel.processes.allSatisfy { $0.pid != local.shellPid }, "remote rows never include local pids")
        let remotePanel = panel(remoteModel, session: remote, remoteProject: project)
        let remoteRow = row(in: remotePanel, for: remoteSleep)
        let titles = remoteRow?.menu?.items.map(\.title) ?? []
        try check(remoteRow != nil, "the remote sleep row is rendered under the remote project")
        try check(titles == [String(localized: "Copy PID"), String(localized: "Copy Executable Path")],
                  "remote rows are read-only")
        let sampled = Date()
        remoteModel.sync(root: "", projectRoot: "", projectRootSource: .shell, shellName: "", shellPid: nil, remote: source)
        try check(Date().timeIntervalSince(sampled) < 0.5, "the sidebar tick does not block on the host")
        print("PASS \(backend) processes: \(checks) checks")
    }
}
