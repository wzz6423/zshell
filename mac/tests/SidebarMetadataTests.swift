import AppKit
import Foundation
import Darwin

nonisolated final class MetadataFixtureState: @unchecked Sendable {
    static let shared = MetadataFixtureState()
    private let lock = NSLock()
    private var held = false
    private var probeNames: [String] = []
    private var active = 0
    private var maxActive = 0
    private var directoryPaths: [Int32: String] = [:]
    func reset(held: Bool = false) { lock.withLock { self.held = held; probeNames = []; active = 0; maxActive = 0; directoryPaths = [:] } }
    func setHeld(_ held: Bool) { lock.withLock { self.held = held } }
    func setDirectory(_ path: String, pid: Int32) { lock.withLock { directoryPaths[pid] = path } }
    func directory(_ pid: Int32) -> String? { lock.withLock { directoryPaths[pid] } }
    func probe(_ name: String) -> String? {
        lock.withLock { probeNames.append(name); active += 1; maxActive = max(maxActive, active) }
        defer { lock.withLock { active -= 1 } }
        while lock.withLock({ held }) { Thread.sleep(forTimeInterval: 0.005) }
        return "branch-" + (name as NSString).lastPathComponent
    }
    var names: [String] { lock.withLock { probeNames } }
    var maximumActive: Int { lock.withLock { maxActive } }
}
nonisolated func processWorkingDirectory(pid: Int32) -> String? { MetadataFixtureState.shared.directory(pid) }
nonisolated func processExecutablePath(pid: Int32) -> String? { "/fixture/program" }
@MainActor final class FixtureSurface { var foregroundPid: Int32? }
@MainActor final class FixtureConnection { var projectDirectory: String? }
@MainActor struct FixtureRemoteStatus { var sessionCommand: [String]? }
@MainActor final class TerminalSession {
    let id = UUID()
    var workingDirectory: String?
    var remoteConnection: FixtureConnection?
    var remoteStatus: FixtureRemoteStatus?
    var hasExited = false
    let surface = FixtureSurface()
    var initialDirectoryPath: String
    init(_ directory: String) { initialDirectoryPath = directory }
}
@MainActor final class Project {
    let conversationHistoryProjectID = UUID()
    let location: ProjectLocation
    var isRemote: Bool { location.isRemote }
    var remoteDirectory: String? {
        switch location { case .local: nil; case .ssh(_, let directory, _, _): directory; case .shared(_, let directory): directory }
    }
    init(_ location: ProjectLocation = .local) { self.location = location }
}

@main @MainActor struct SidebarMetadataTests {
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003)) }
    }
    static func wait(_ label: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { pump(0.01) }
        precondition(condition(), label)
    }
    static func check(_ condition: Bool, _ label: String) { precondition(condition, label); print("PASS metadata: \(label)") }
    static func main() throws {
        setbuf(stdout, nil)
        let state = MetadataFixtureState.shared
        let model = ProjectSidebarMetadata()
        let project = Project()
        var changes = 0
        model.onChange = { changes += 1 }
        state.reset()
        let many = (0..<100).map { TerminalSession("/fixture/\($0)") }
        model.refresh(sessions: many.map { ($0, project) })
        wait("bounded first batch") { model.entry(for: many[0].id) != nil }
        check(many.filter { model.entry(for: $0.id) != nil }.count == 64, "one batch resolves at most 64 visible sessions")
        check(state.names.count == 4, "one batch performs at most four branch probes")
        check(state.maximumActive == 1, "branch operations remain serial")
        model.clear()

        state.reset(held: true)
        let old = TerminalSession("/fixture/old"), next = TerminalSession("/fixture/next"), latest = TerminalSession("/fixture/latest")
        model.refresh(sessions: [(old, project)])
        wait("old worker started") { state.names.count == 1 }
        let start = Date()
        model.refresh(sessions: [(next, project)])
        model.refresh(sessions: [(latest, project)])
        check(Date().timeIntervalSince(start) < 0.1, "scroll invalidation never blocks the main actor")
        pump(0.1)
        check(state.names.count == 1 && state.maximumActive == 1, "scrolling does not start another worker while a probe is blocked")
        state.setHeld(false)
        wait("latest row published") { model.entry(for: latest.id) != nil }
        check(model.entry(for: old.id) == nil && model.entry(for: next.id) == nil, "only the newest visible row is published")
        check(!state.names.contains("/fixture/next"), "superseded pending rows never start probes")
        let beforeClear = changes
        model.clear()
        check(changes == beforeClear + 1 && model.entry(for: latest.id) == nil, "cache clearing invalidates visible labels")

        state.reset(held: true)
        model.refresh(sessions: [(old, project), (next, project)])
        wait("fold fixture started") { state.names.count == 1 }
        let beforeFold = changes
        model.clear()
        state.setHeld(false)
        pump(0.3)
        check(state.names.count == 1, "folding cancels the batch before another command starts")
        check(model.entry(for: old.id) == nil && model.entry(for: next.id) == nil && changes == beforeFold,
              "a folded sidebar never republishes canceled metadata")

        state.reset()
        old.workingDirectory = "file:///fixture/first"
        model.refresh(sessions: [(old, project)])
        wait("first directory") { model.entry(for: old.id)?.directory == "/fixture/first" }
        old.workingDirectory = "file:///fixture/second"
        model.refresh(sessions: [(old, project)])
        wait("changed directory") { model.entry(for: old.id)?.directory == "/fixture/second" }
        check(model.entry(for: old.id)?.branch == "branch-second", "directory changes invalidate a request with the same session ID")
        state.setDirectory("/fixture/foreground", pid: 42)
        old.surface.foregroundPid = 42
        model.refresh(sessions: [(old, project)])
        wait("foreground directory") { model.entry(for: old.id)?.directory == "/fixture/foreground" }
        check(model.entry(for: old.id)?.program == "program", "foreground PID changes refresh process metadata off the main actor")
        model.clear()

        state.reset(held: true)
        let endpoint = try SSHEndpoint(host: "fixture.invalid")
        let remote = Project(.ssh(endpoint: endpoint, remoteDirectory: "/fixture/shared"))
        let remoteOne = TerminalSession("/fixture/shared"), remoteTwo = TerminalSession("/fixture/other")
        model.refresh(sessions: [(remoteOne, remote), (remoteTwo, remote)])
        wait("remote blocked command") { state.names.count == 1 }
        model.clear()
        state.setHeld(false)
        pump(0.3)
        check(state.names == ["ssh:/fixture/shared"], "remote cancellation prevents the second SSH request and never probes local paths")
        check(model.entry(for: remoteOne.id) == nil, "canceled remote metadata never reaches the visible cache")
        state.reset()
        model.refresh(sessions: [(remoteOne, remote)])
        wait("remote result") { model.entry(for: remoteOne.id) != nil }
        check(model.entry(for: remoteOne.id)?.branch == "branch-shared" && state.names == ["ssh:/fixture/shared"],
              "remote metadata uses the remote symbolic-ref result")
        model.clear()
        print("SIDEBAR METADATA 15 passed")
    }
}
