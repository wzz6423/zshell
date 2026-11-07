import AppKit
import Combine
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor private var checks = 0

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
    checks += 1
}

@MainActor private func eventually(_ label: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestFailure(description: "Timed out: \(label)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor private final class TestClock {
    var time: TimeInterval = 100
    func advance(_ seconds: TimeInterval = 5) { time += seconds }
}

private nonisolated final class ListingFixture: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let destination: String
        let directory: String
    }

    private let condition = NSCondition()
    private var responses: [String: Result<[SSHEndpoint.DirectoryEntry], Error>] = [:]
    private var held: Set<String> = []
    private var active = 0
    private var maximum = 0
    private var log: [Request] = []

    func set(_ directory: String, _ names: [String]) {
        condition.lock()
        defer { condition.unlock() }
        responses[directory] = .success(names.map {
            SSHEndpoint.DirectoryEntry(name: $0.hasSuffix("/") ? String($0.dropLast()) : $0,
                                       isDirectory: $0.hasSuffix("/"))
        })
    }

    func fail(_ directory: String, _ message: String = "Fixture offline") {
        condition.lock()
        defer { condition.unlock() }
        responses[directory] = .failure(TestFailure(description: message))
    }

    func hold(_ directory: String) {
        condition.lock()
        held.insert(directory)
        condition.unlock()
    }

    func release(_ directory: String? = nil) {
        condition.lock()
        if let directory { held.remove(directory) } else { held = [] }
        condition.broadcast()
        condition.unlock()
    }

    func list(_ endpoint: SSHEndpoint, _ directory: String) throws -> [SSHEndpoint.DirectoryEntry] {
        condition.lock()
        defer { active -= 1; condition.unlock() }
        active += 1
        maximum = max(maximum, active)
        log.append(Request(destination: endpoint.destination, directory: directory))
        let response = responses[directory] ?? .success([])
        let deadline = Date().addingTimeInterval(8)
        while held.contains(directory) {
            guard condition.wait(until: deadline) else {
                throw TestFailure(description: "Fixture request was never released: \(directory)")
            }
        }
        return try response.get()
    }

    var requests: [Request] {
        condition.lock()
        defer { condition.unlock() }
        return log
    }

    var maximumActive: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximum
    }

    func count(_ directory: String) -> Int { requests.filter { $0.directory == directory }.count }
}

@MainActor private func model(_ fixture: ListingFixture, _ clock: TestClock) throws -> FileTreeModel {
    let model = FileTreeModel(remoteListing: { try fixture.list($0, $1) }, remoteNow: { clock.time })
    model.configureRemote(try SSHEndpoint(host: "fixture.invalid"))
    return model
}

@MainActor private func directory(_ name: String, in model: FileTreeModel) throws -> FileTreeModel.Item {
    guard let item = model.items.first(where: { $0.name == name && $0.isDirectory }) else {
        throw TestFailure(description: "Missing directory: \(name)")
    }
    return item
}

@MainActor private func cachedRootAndThrottle() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/repo", ["initial.txt"])
    model.sync(root: "/repo")
    try await eventually("initial listing") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["initial.txt"], "Initial listing is visible")
    fixture.set("/repo", ["new.txt", "initial.txt"])
    for _ in 0..<500 { model.sync(root: "/repo") }
    clock.advance(4.99)
    model.sync(root: "/repo")
    try await Task.sleep(for: .milliseconds(10))
    try require(fixture.count("/repo") == 1, "Rapid syncs and a fresh cache launch no new request")
    clock.advance(0.01)
    model.sync(root: "/repo")
    try await eventually("external addition") { model.items.count == 2 && !model.isRemoteLoading }
    try require(fixture.count("/repo") == 2, "An expired cached listing is fetched again")
    fixture.set("/repo", ["renamed.txt"])
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("external removal and rename") {
        model.items.map(\.name) == ["renamed.txt"] && !model.isRemoteLoading
    }
    var publications = 0
    let observation = model.$items.dropFirst().sink { _ in publications += 1 }
    defer { observation.cancel() }
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("unchanged refresh") { !model.isRemoteLoading }
    try require(publications == 0, "Unchanged listings publish no replacement rows")
    print("PASS cached root refresh, addition/removal/rename, 5-second throttle, stable rows")
}

@MainActor private func expandedChildrenAndErrors() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/repo", ["folder/", "root.txt"])
    fixture.set("/repo/folder", ["child.txt", "nested/"])
    fixture.set("/repo/folder/nested", ["before.txt"])
    model.sync(root: "/repo")
    try await eventually("root with directory") { !model.isRemoteLoading }
    let folder = try directory("folder", in: model)
    model.toggle(folder)
    try await eventually("expanded child") { model.items.contains { $0.name == "child.txt" } }
    let nested = try directory("nested", in: model)
    model.toggle(nested)
    try await eventually("expanded descendant") { model.items.contains { $0.name == "before.txt" } }
    fixture.set("/repo/folder", ["nested/", "new-child.txt"])
    fixture.set("/repo/folder/nested", ["after.txt"])
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("refresh expanded descendants") {
        !model.isRemoteLoading && model.items.contains { $0.name == "after.txt" }
    }
    try require(model.items.contains { $0.name == "new-child.txt" }, "Sync refreshes expanded child directories")
    try require(!model.items.contains { $0.name == "child.txt" || $0.name == "before.txt" },
                "Deleted and renamed children leave the visible tree")
    fixture.fail("/repo/folder/nested")
    fixture.hold("/repo")
    defer { fixture.release() }
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("descendant error") { model.remoteError != nil }
    try require(model.items.contains { $0.name == "after.txt" }, "Failed refresh retains its cached rows")
    fixture.release("/repo")
    try await eventually("root completed after descendant failure") { !model.isRemoteLoading }
    try require(model.remoteError != nil, "Root success cannot clear a visible descendant's error")
    model.toggle(folder)
    try require(model.remoteError == nil, "Collapsed descendant failures are removed from the banner")
    let nestedRequests = fixture.count("/repo/folder/nested")
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("collapsed sync") { !model.isRemoteLoading }
    try require(fixture.count("/repo/folder/nested") == nestedRequests, "Hidden descendants are not polled")
    fixture.set("/repo/folder/nested", ["recovered.txt"])
    model.toggle(folder)
    try await eventually("reopening ancestor") { !model.isRemoteLoading }
    model.sync(root: "/repo")
    try await eventually("reopening descendant") {
        !model.isRemoteLoading && model.items.contains { $0.name == "recovered.txt" }
    }
    try require(model.remoteError == nil, "A reopened descendant recovers after its failure")
    print("PASS expanded child/descendant refresh, cached errors, visibility, recovery")
}

@MainActor private func failuresAndRetry() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.fail("/repo")
    model.sync(root: "/repo")
    try await eventually("initial failure") { !model.isRemoteLoading }
    try require(model.remoteError != nil && model.items.isEmpty, "Initial failure is surfaced")
    for _ in 0..<500 { model.sync(root: "/repo") }
    try require(fixture.count("/repo") == 1, "Initial failures are also throttled")
    fixture.set("/repo", ["folder/", "kept.txt"])
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("automatic root recovery") { !model.isRemoteLoading && !model.items.isEmpty }
    try require(model.remoteError == nil, "Expired failed listing recovers without manual retry")
    fixture.fail("/repo")
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("cached root failure") { !model.isRemoteLoading }
    try require(model.items.contains { $0.name == "kept.txt" }, "Root refresh failure keeps the old contents")
    fixture.set("/repo", ["folder/", "recovered.txt"])
    model.retryRemoteRoot()
    try await eventually("manual root recovery inside throttle") { !model.isRemoteLoading }
    try require(model.items.contains { $0.name == "recovered.txt" } && model.remoteError == nil,
                "Retry bypasses the throttle even with cached contents")
    fixture.set("/repo/folder", ["old-child.txt"])
    model.toggle(try directory("folder", in: model))
    try await eventually("child before failure") { !model.isRemoteLoading }
    fixture.fail("/repo/folder")
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("child refresh failure") { !model.isRemoteLoading }
    try require(model.remoteError != nil, "A child refresh failure is visible")
    fixture.set("/repo/folder", ["new-child.txt"])
    let previous = fixture.count("/repo/folder")
    model.retryRemoteRoot()
    try await eventually("manual child recovery") { !model.isRemoteLoading }
    try require(fixture.count("/repo/folder") == previous + 1
                && model.items.contains { $0.name == "new-child.txt" } && model.remoteError == nil,
                "Retry also bypasses throttling for visible failed children")
    print("PASS initial/cached failure throttling, automatic recovery, root/child manual retry")
}

@MainActor private func boundedSchedulingAndFairness() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    let names = (0..<8).map { "folder\($0)/" }
    fixture.set("/repo", names)
    model.sync(root: "/repo")
    try await eventually("scheduler root") { !model.isRemoteLoading }
    for index in 0..<8 {
        let path = "/repo/folder\(index)"
        fixture.set(path, ["child\(index).txt"])
        fixture.hold(path)
        model.toggle(try directory("folder\(index)", in: model))
    }
    defer { fixture.release() }
    try await eventually("two active requests") { fixture.requests.count == 3 }
    for _ in 0..<1000 { model.sync(root: "/repo") }
    try await Task.sleep(for: .milliseconds(10))
    try require(fixture.requests.count == 3 && fixture.maximumActive == 2,
                "Repeated syncs cannot exceed two requests or enqueue duplicate directory work")
    model.toggle(try directory("folder7", in: model))
    fixture.release()
    try await eventually("bounded queue drained") { !model.isRemoteLoading }
    let beforeFreshSyncs = fixture.requests.count
    for _ in 0..<200 { model.sync(root: "/repo") }
    try await Task.sleep(for: .milliseconds(10))
    try require(fixture.requests.count == beforeFreshSyncs, "A burst after completions cannot bypass the throttle")
    for index in 0..<7 {
        try require(fixture.count("/repo/folder\(index)") == 1, "Each pending directory is listed once")
    }
    try require(fixture.count("/repo/folder7") == 0, "Collapsing a queued directory drops its request")
    clock.advance(1)
    model.retryRemoteRoot()
    try await eventually("more recent root") { !model.isRemoteLoading }
    for index in 0..<7 { fixture.hold("/repo/folder\(index)") }
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("older child requests scheduled") { fixture.requests.count == 11 }
    try require(fixture.count("/repo") == 2, "Older children precede the more recent root")
    clock.advance(50)
    for _ in 0..<1000 { model.sync(root: "/repo") }
    fixture.release()
    try await eventually("root and all children eventually refreshed") { !model.isRemoteLoading }
    try require(fixture.count("/repo") >= 3, "Failing or stale child work cannot starve the root")
    for index in 0..<7 {
        try require(fixture.count("/repo/folder\(index)") >= 2, "Every expanded directory gets another turn")
    }
    try require(fixture.maximumActive <= 2, "Concurrency remains bounded while the clock advances")
    print("PASS request limit, burst coalescing, pending collapse, root/child fairness")
}

@MainActor private func parentRemovalAndReplacement() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/repo", ["folder/", "stable.txt"])
    fixture.set("/repo/folder", ["old.txt", "nested/"])
    fixture.set("/repo/folder/nested", ["nested-old.txt"])
    model.sync(root: "/repo")
    try await eventually("parent replacement root") { !model.isRemoteLoading }
    model.toggle(try directory("folder", in: model))
    try await eventually("parent replacement child") { !model.isRemoteLoading }
    model.toggle(try directory("nested", in: model))
    try await eventually("parent replacement nested child") { !model.isRemoteLoading }
    fixture.set("/repo", ["folder", "stable.txt"])
    fixture.set("/repo/folder", ["obsolete.txt"])
    fixture.hold("/repo/folder")
    defer { fixture.release() }
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("parent changed directory into file") {
        model.items.contains { $0.name == "folder" && !$0.isDirectory }
            && fixture.count("/repo/folder") == 2
    }
    try require(!model.items.contains { $0.depth > 0 }, "Changing a directory into a file removes its children")
    fixture.set("/repo", ["folder/", "stable.txt"])
    fixture.set("/repo/folder", ["replacement.txt"])
    model.retryRemoteRoot()
    try await eventually("same-path replacement directory") {
        model.items.contains { $0.name == "folder" && $0.isDirectory }
    }
    try require(!model.items.contains { $0.name == "old.txt" || $0.name == "obsolete.txt" },
                "A replacement directory cannot reuse the removed directory's cache")
    model.sync(root: "/repo")
    var stalePublication = false
    let observation = model.$items.dropFirst().sink { items in
        if items.contains(where: { $0.name == "obsolete.txt" }) { stalePublication = true }
    }
    defer { observation.cancel() }
    fixture.release("/repo/folder")
    try await eventually("replacement directory refreshed without toggling") { !model.isRemoteLoading }
    try require(model.items.contains { $0.name == "replacement.txt" } && !stalePublication,
                "A late removed-directory result is rejected before a new same-path listing")
    try require(!model.items.contains { $0.name == "nested-old.txt" }, "Removed descendant caches are discarded")
    fixture.set("/repo", ["renamed-folder/", "stable.txt"])
    clock.advance()
    model.sync(root: "/repo")
    try await eventually("parent directory renamed") { !model.isRemoteLoading }
    try require(!model.items.contains { $0.path.hasPrefix("/repo/folder") },
                "An external directory rename removes the old subtree")
    let oldRequests = fixture.count("/repo/folder")
    clock.advance()
    for _ in 0..<200 { model.sync(root: "/repo") }
    try await eventually("renamed parent stable sync") { !model.isRemoteLoading }
    try require(fixture.count("/repo/folder") == oldRequests, "Removed directories are no longer requested")
    print("PASS parent directory/file replacement, descendant invalidation, late child rejection, rename")
}

@MainActor private func retryWhileBusy() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/repo", ["a/", "b/"])
    model.sync(root: "/repo")
    try await eventually("retry scheduler root") { !model.isRemoteLoading }
    fixture.set("/repo/a", ["a.txt"])
    fixture.fail("/repo/b")
    fixture.hold("/repo/a")
    fixture.hold("/repo/b")
    defer { fixture.release() }
    model.toggle(try directory("a", in: model))
    model.toggle(try directory("b", in: model))
    try await eventually("retry busy workers") { fixture.requests.count == 3 }
    fixture.set("/repo", ["a/", "b/", "retry.txt"])
    for _ in 0..<100 { model.retryRemoteRoot() }
    try require(fixture.count("/repo") == 1 && fixture.maximumActive == 2,
                "Forced retries wait for a slot instead of opening more connections")
    fixture.release("/repo/a")
    try await eventually("queued forced root") { model.items.contains { $0.name == "retry.txt" } }
    try require(fixture.count("/repo") == 2, "Multiple queued retries coalesce and bypass the throttle")
    model.toggle(try directory("b", in: model))
    try require(!model.isRemoteLoading, "A collapsed in-flight directory no longer drives visible loading")
    fixture.release("/repo/b")
    try await Task.sleep(for: .milliseconds(20))
    try require(model.remoteError == nil, "A late hidden-directory failure cannot raise the banner")
    print("PASS forced retry queuing/coalescing, concurrency cap, collapsed loading")
}

@MainActor private func samePathsAfterRoundTrips() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/a", ["stale-a.txt"])
    fixture.set("/b", ["stale-b.txt"])
    fixture.hold("/a")
    fixture.hold("/b")
    defer { fixture.release() }
    model.sync(root: "/a")
    model.sync(root: "/b")
    try await eventually("root round-trip workers") { fixture.requests.count == 2 }
    fixture.set("/a", ["fresh-a.txt"])
    model.sync(root: "/a")
    fixture.release("/a")
    try await eventually("fresh root after A/B/A") { model.items.map(\.name) == ["fresh-a.txt"] }
    fixture.release("/b")
    try await Task.sleep(for: .milliseconds(20))
    try require(model.items.map(\.name) == ["fresh-a.txt"] && model.remoteError == nil,
                "Root A/B/A rejects both older roots and preserves the newest same-path request")
    fixture.set("/a", ["stale-host.txt"])
    fixture.hold("/a")
    clock.advance()
    model.sync(root: "/a")
    try await eventually("first host old worker") { fixture.count("/a") == 3 }
    model.configureRemote(try SSHEndpoint(host: "second.invalid"))
    model.sync(root: "/a")
    model.configureRemote(try SSHEndpoint(host: "fixture.invalid"))
    fixture.set("/a", ["fresh-host.txt"])
    model.sync(root: "/a")
    var stalePublication = false
    let observation = model.$items.dropFirst().sink { items in
        if items.contains(where: { $0.name == "stale-host.txt" }) { stalePublication = true }
    }
    defer { observation.cancel() }
    fixture.release("/a")
    try await eventually("endpoint round trip same path") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["fresh-host.txt"] && !stalePublication,
                "Endpoint A/B/A rejects an old result even when endpoint and path match again")
    try require(fixture.requests.filter { $0.destination == "second.invalid" }.isEmpty,
                "An intermediate endpoint's pending work is discarded")
    try require(fixture.maximumActive <= 2, "Round trips do not remove newer connection accounting")
    print("PASS root and endpoint A/B/A round trips at the same path")
}

@MainActor private func staleRootsAndEndpoints() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    fixture.set("/old", ["old.txt"])
    fixture.hold("/old")
    defer { fixture.release() }
    model.sync(root: "/old")
    try await eventually("old root in flight") { fixture.count("/old") == 1 }
    fixture.set("/new", ["new.txt"])
    model.sync(root: "/new")
    try await eventually("new root completed first") { model.items.map(\.name) == ["new.txt"] }
    fixture.release("/old")
    try await Task.sleep(for: .milliseconds(20))
    try require(model.items.map(\.name) == ["new.txt"] && model.remoteError == nil,
                "An older root cannot overwrite the new listing")
    fixture.fail("/new")
    fixture.hold("/new")
    clock.advance()
    model.sync(root: "/new")
    try await eventually("old endpoint in flight") { fixture.count("/new") == 2 }
    fixture.set("/new", ["new-host.txt"])
    model.configureRemote(try SSHEndpoint(host: "second.invalid"))
    model.sync(root: "/new")
    try require(model.items.isEmpty && model.remoteError == nil, "Endpoint switch clears old visible state")
    fixture.release("/new")
    try await eventually("new endpoint same path") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["new-host.txt"] && model.remoteError == nil,
                "Old endpoint failure cannot contaminate the new endpoint at the same root")
    try require(fixture.requests.last?.destination == "second.invalid", "Fresh request targets the new host")
    fixture.hold("/new")
    clock.advance()
    model.sync(root: "/new")
    try await eventually("empty-root old worker") { fixture.count("/new") == 4 }
    model.sync(root: "")
    fixture.release("/new")
    try await Task.sleep(for: .milliseconds(20))
    try require(model.items.isEmpty && model.remoteError == nil && !model.isRemoteLoading,
                "Clearing the root discards old work and loading")
    print("PASS late root/endpoint results, same-path endpoint changes, empty roots")
}

@MainActor private func rapidRootChangesStayBounded() async throws {
    let fixture = ListingFixture()
    let clock = TestClock()
    let model = try model(fixture, clock)
    for index in 0..<20 {
        fixture.set("/root\(index)", ["file\(index).txt"])
        fixture.hold("/root\(index)")
    }
    defer { fixture.release() }
    model.sync(root: "/root0")
    model.sync(root: "/root1")
    try await eventually("two older roots") { fixture.requests.count == 2 }
    for index in 2..<20 { model.sync(root: "/root\(index)") }
    try require(fixture.requests.count == 2 && model.isRemoteLoading, "Old roots retain connection slots")
    fixture.release()
    try await eventually("latest root wins") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["file19.txt"], "Only the final root can publish contents")
    try require(fixture.requests.count == 3 && fixture.count("/root19") == 1,
                "Intermediate root candidates are dropped rather than accumulated")
    try require(fixture.maximumActive <= 2, "Rapid root changes cannot pile up transport requests")
    print("PASS rapid root changes, old connection accounting, newest pending root only")
}

@MainActor private func productionTransport(_ temporary: URL, _ ssh: URL) async throws {
    let fm = FileManager.default
    let root = temporary.appendingPathComponent("remote '项目 with spaces", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let initial = root.appendingPathComponent("initial.txt")
    try Data("initial".utf8).write(to: initial)
    try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
    let clock = TestClock()
    let model = FileTreeModel(remoteListing: { endpoint, path in
        try OpenSSHTransport(executableURL: ssh, timeout: 2).listDirectory(endpoint: endpoint, directory: path)
    }, remoteNow: { clock.time })
    model.configureRemote(try SSHEndpoint(host: "fixture.invalid"))
    model.sync(root: root.path)
    try await eventually("production transport initial listing") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["initial.txt"], "Production ls parser hides .git")
    let newFile = root.appendingPathComponent("new.txt")
    try Data("new".utf8).write(to: newFile)
    for _ in 0..<3 { clock.advance(2); model.sync(root: root.path) }
    try await eventually("production transport external addition") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["initial.txt", "new.txt"],
                "Three normal 2-second syncs discover an externally created file")
    try fm.removeItem(at: initial)
    try fm.moveItem(at: newFile, to: root.appendingPathComponent("renamed.txt"))
    clock.advance()
    model.sync(root: root.path)
    try await eventually("production transport rename/delete") { !model.isRemoteLoading }
    try require(model.items.map(\.name) == ["renamed.txt"], "Production transport observes deletion and rename")
    let failure = temporary.appendingPathComponent("fail")
    try Data().write(to: failure)
    clock.advance()
    model.sync(root: root.path)
    try await eventually("production transport failure") { !model.isRemoteLoading }
    try require(model.remoteError != nil && model.items.map(\.name) == ["renamed.txt"],
                "Production process failure preserves the cached listing")
    try fm.removeItem(at: failure)
    model.retryRemoteRoot()
    try await eventually("production transport retry") { !model.isRemoteLoading }
    try require(model.remoteError == nil, "Production transport recovers immediately with Retry")
    let requests = try String(contentsOf: temporary.appendingPathComponent("requests"), encoding: .utf8)
    try require(requests.split(separator: "\n").count == 5, "Production path makes exactly five bounded requests")
    print("PASS production SSH transport/process/parser path with private fake executable; no network or credentials")
}

@main struct RemoteFileTreeRefreshTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        try require(CommandLine.arguments.count == 3, "Pass a temporary fixture directory and SSH executable")
        try await cachedRootAndThrottle()
        try await expandedChildrenAndErrors()
        try await failuresAndRetry()
        try await boundedSchedulingAndFairness()
        try await retryWhileBusy()
        try await staleRootsAndEndpoints()
        try await rapidRootChangesStayBounded()
        try await samePathsAfterRoundTrips()
        try await parentRemovalAndReplacement()
        try await productionTransport(URL(fileURLWithPath: CommandLine.arguments[1]),
                                      URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Remote file tree refresh: \(checks) checks passed")
    }
}
