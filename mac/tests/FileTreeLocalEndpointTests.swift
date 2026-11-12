import AppKit
import Darwin
import Foundation

nonisolated enum SSHAuthentication {
    case agent
    func arguments(identityFile: String?) -> [String] { [] }
}

@MainActor enum AppWindowPresentation {
    static func hostWindow() -> NSWindow? { nil }
}

@MainActor final class TerminalSession {
    var currentDirectoryPath = ""
    var foregroundDirectoryPath: String?
    var shellName = "zsh"
    var shellPid: pid_t? = 42
    var remoteConnection: RemoteConnectionFixture?
}

struct RemoteConnectionFixture {
    let host: String
    let projectDirectory: String
    let sessionID: UUID
}

enum PaneContent {
    case session(TerminalSession)
    case file
    case diff
}

struct PaneTab {
    var sessions: [TerminalSession] = []
    var contextSession: TerminalSession?
}

@MainActor final class Project {
    var isRemote = false
    var remoteEndpoint: SSHEndpoint?
    var remoteDirectory: String?
    var customDirectory: String?
    var focusedContent: PaneContent?
    var selectedTab: PaneTab?
    var sessions: [TerminalSession] = []
}

@MainActor final class ContentSearchFixture {
    private(set) var rootPath = ""
    func sync(root: String) { rootPath = root }
}

@MainActor final class ManagerFixture {
    var isPanelVisible = true
    var selectedProject: Project?
    var panelTab = RightPanel.files
    let fileContentSearch = ContentSearchFixture()
    let fileTree = FileTreeModel()
    var fileTreeImportDirectory: String?
    var selectedSession: TerminalSession? { selectedProject?.selectedSession }
}

@MainActor final class FileTreeImportController {
    static let shared = FileTreeImportController()
    var isImporting = false
    var chosenDirectory: String?
    var error: Error?

    func chooseFiles(manager: ManagerFixture, directory: String) {
        chosenDirectory = directory
        do { _ = try FileTreeImportService.destination(root: manager.fileTree.rootPath, directory: directory) }
        catch { self.error = error }
    }
}

@MainActor final class SessionInfoModel {
    struct RemoteSource {
        let host: String
        let directory: String
        let sessionID: UUID
    }

    private(set) var rootPath = ""

    func sync(root: String, projectRoot: String, projectRootSource: Project.PanelRootSource,
              shellName: String, shellPid: pid_t?, remote: RemoteSource? = nil) {
        rootPath = root
    }
}

@MainActor final class SidebarFixture {
    let manager = ManagerFixture()
    var fileTree: FileTreeModel { manager.fileTree }
    let info = SessionInfoModel()
    var rootSource = Project.PanelRootSource.shell
}

nonisolated enum FixtureFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}

nonisolated final class ListingFixture: @unchecked Sendable {
    struct Request {
        let endpoint: SSHEndpoint
        let directory: String
    }

    static let shared = ListingFixture()
    private let condition = NSCondition()
    private var requests: [Request] = []
    private var results: [Int: Result<[SSHEndpoint.DirectoryEntry], Error>] = [:]
    private var automaticListings: [String: [SSHEndpoint.DirectoryEntry]] = [:]
    private var returned: Set<Int> = []

    var requestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return requests.count
    }

    var returnedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return returned.count
    }

    func request(at index: Int) -> Request {
        condition.lock()
        defer { condition.unlock() }
        return requests[index]
    }

    func complete(_ index: Int, with result: Result<[SSHEndpoint.DirectoryEntry], Error>) {
        condition.lock()
        defer { condition.unlock() }
        results[index] = result
        condition.broadcast()
    }

    func automaticallyComplete(_ listings: [String: [SSHEndpoint.DirectoryEntry]]) {
        condition.lock()
        defer { condition.unlock() }
        automaticListings = listings
        condition.broadcast()
    }

    func list(endpoint: SSHEndpoint, directory: String) throws -> [SSHEndpoint.DirectoryEntry] {
        condition.lock()
        defer { condition.unlock() }
        let index = requests.count
        requests.append(Request(endpoint: endpoint, directory: directory))
        let deadline = Date().addingTimeInterval(5)
        while results[index] == nil && automaticListings[directory] == nil {
            guard condition.wait(until: deadline) else {
                throw FixtureFailure.failed("SSH fixture completion timed out")
            }
        }
        returned.insert(index)
        if let result = results.removeValue(forKey: index) { return try result.get() }
        return automaticListings[directory]!
    }
}

nonisolated struct OpenSSHTransport {
    func listDirectory(endpoint: SSHEndpoint, directory: String) throws -> [SSHEndpoint.DirectoryEntry] {
        try ListingFixture.shared.list(endpoint: endpoint, directory: directory)
    }
}

@main struct FileTreeLocalEndpointTests {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("File tree endpoint regression: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw FixtureFailure.failed(message) }
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            try check(Date() < deadline, "Timed out waiting for the production model")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor private static func run() async throws {
        let scenario = CommandLine.arguments[1]
        let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let localRoot = fixtureRoot.appendingPathComponent("local", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixtureRoot) }
        try Data("local fixture".utf8).write(to: localRoot.appendingPathComponent("local.txt"))
        let endpointA = try SSHEndpoint(host: "alpha.example.invalid", user: "fixture", port: 2222)
        let endpointB = try SSHEndpoint(host: "beta.example.invalid", user: "fixture", port: 2222)
        let remoteRoot = scenario == "same-root" ? localRoot.path : "/remote/work"
        let sidebar = SidebarFixture()
        let transport = ListingFixture.shared

        func project(root: String, endpoint: SSHEndpoint? = nil, remote: Bool = false) -> Project {
            let project = Project()
            project.isRemote = remote
            project.remoteEndpoint = endpoint
            project.remoteDirectory = remote ? root : nil
            let session = TerminalSession()
            session.currentDirectoryPath = root
            project.sessions = [session]
            return project
        }

        func checkLocal() async throws {
            try check(!sidebar.fileTree.isRemote, "Local refresh retained the previous SSH endpoint")
            try await waitUntil {
                sidebar.fileTree.rootPath == localRoot.path && sidebar.fileTree.items.map(\.name) == ["local.txt"]
            }
            try check(sidebar.fileTree.rootPath == localRoot.path, "Local refresh used the wrong root")
            try check(sidebar.fileTree.items.map(\.name) == ["local.txt"], "Local files were replaced by a remote listing")
            try check(sidebar.fileTree.rootSubtitle == localRoot.path, "The local header still names the SSH host")
            try check(sidebar.manager.fileContentSearch.rootPath == localRoot.path, "Search and tree roots diverged")
        }

        func checkEmpty() async throws {
            try check(!sidebar.fileTree.isRemote, "Empty selection retained the previous SSH endpoint")
            try await waitUntil { sidebar.fileTree.rootPath.isEmpty && sidebar.fileTree.items.isEmpty }
            try check(sidebar.fileTree.rootPath.isEmpty && sidebar.fileTree.items.isEmpty,
                      "Empty selection retained the previous remote tree")
            try check(sidebar.fileTree.rootSubtitle.isEmpty, "Empty selection retained the SSH header")
        }

        sidebar.manager.selectedProject = project(root: remoteRoot, endpoint: endpointA, remote: true)
        sidebar.refresh()
        try await waitUntil { transport.requestCount == 1 }
        try check(transport.request(at: 0).endpoint == endpointA
                  && transport.request(at: 0).directory == remoteRoot, "Initial refresh used the wrong SSH target")
        if !scenario.hasPrefix("late-") {
            transport.complete(0, with: .success([
                .init(name: "remote.txt", isDirectory: false),
                .init(name: "folder", isDirectory: true),
            ]))
            try await waitUntil { !sidebar.fileTree.isRemoteLoading }
            try check(sidebar.fileTree.isRemote && sidebar.fileTree.items.map(\.name) == ["folder", "remote.txt"],
                      "The fixture did not establish a remote tree")
        }

        switch scenario {
        case let scenario where scenario.hasPrefix("import-"):
            let firstRoot = fixtureRoot.appendingPathComponent("project-a")
            try fm.createDirectory(at: firstRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
            sidebar.manager.selectedProject = project(root: firstRoot.path)
            sidebar.refresh()
            sidebar.manager.fileTreeImportDirectory = firstRoot.appendingPathComponent("sub").path
            sidebar.manager.selectedProject = project(root: localRoot.path)
            sidebar.refresh()
            if scenario == "import-project-switch" {
                try check(sidebar.fileTree.rootPath == localRoot.path
                          && sidebar.manager.fileTreeImportDirectory == firstRoot.appendingPathComponent("sub").path,
                          "Sidebar root switch must exercise a saved folder from the previous project")
            } else {
                let selected = localRoot.appendingPathComponent("selected")
                try fm.createDirectory(at: selected, withIntermediateDirectories: false)
                sidebar.manager.fileTreeImportDirectory = selected.path
                switch scenario {
                case "import-deleted": try fm.removeItem(at: selected)
                case "import-file-replaced":
                    try fm.removeItem(at: selected)
                    try Data("now a file".utf8).write(to: selected)
                case "import-symlink-escape":
                    try fm.removeItem(at: selected)
                    try fm.createSymbolicLink(at: selected, withDestinationURL: firstRoot)
                case "import-valid", "import-explicit": break
                default: throw FixtureFailure.failed("Unknown import scenario")
                }
            }
            let explicit = localRoot.appendingPathComponent("explicit")
            if scenario == "import-explicit" { try fm.createDirectory(at: explicit, withIntermediateDirectories: false) }
            sidebar.manager.importFiles(into: scenario == "import-explicit" ? explicit.path : nil)
            let expected = scenario == "import-valid" ? localRoot.appendingPathComponent("selected").path
                : scenario == "import-explicit" ? explicit.path : localRoot.path
            try check(FileTreeImportController.shared.chosenDirectory == expected,
                      "File menu did not choose the live saved folder or current root: \(FileTreeImportController.shared.chosenDirectory ?? "nil")")
            try check(FileTreeImportController.shared.error == nil, "Chosen destination failed production validation")
            if !["import-valid", "import-explicit"].contains(scenario) {
                try check(sidebar.manager.fileTreeImportDirectory == nil, "Stale saved import directory was retained")
            }
        case "local", "same-root", "empty-root":
            let root = scenario == "empty-root" ? "" : localRoot.path
            sidebar.manager.selectedProject = project(root: root)
            sidebar.refresh()
            if root.isEmpty { try await checkEmpty() } else { try await checkLocal() }
        case "no-project", "no-session", "unavailable-endpoint":
            if scenario == "no-project" {
                sidebar.manager.selectedProject = nil
            } else if scenario == "no-session" {
                let empty = project(root: localRoot.path)
                empty.customDirectory = localRoot.path
                empty.sessions = []
                sidebar.manager.selectedProject = empty
                sidebar.manager.panelTab = .git
            } else {
                sidebar.manager.selectedProject = project(root: remoteRoot, remote: true)
            }
            sidebar.refresh()
            try await checkEmpty()
        case "file-context", "diff-context":
            let local = project(root: localRoot.path)
            let context = local.sessions[0]
            local.sessions = []
            local.selectedTab = PaneTab(contextSession: context)
            local.focusedContent = scenario == "file-context" ? .file : .diff
            sidebar.manager.selectedProject = local
            sidebar.refresh()
            try check(local.selectedSession === context, "An open file/diff lost its terminal context")
            try await checkLocal()
        case "tabs":
            sidebar.manager.selectedProject = project(root: localRoot.path)
            for tab in [RightPanel.info, .git, .files] {
                sidebar.manager.panelTab = tab
                sidebar.refresh()
                try check(!sidebar.fileTree.isRemote, "Local \(tab.rawValue) selection retained the SSH endpoint")
            }
            try check(sidebar.info.rootPath == localRoot.path, "Info no longer follows the local shell")
            try await checkLocal()
        case "remote-switch":
            sidebar.manager.selectedProject = project(root: remoteRoot, endpoint: endpointB, remote: true)
            sidebar.refresh()
            try await waitUntil { transport.requestCount == 2 }
            try check(transport.request(at: 1).endpoint == endpointB
                      && transport.request(at: 1).directory == remoteRoot, "A host switch retained the old SSH target")
            try check(sidebar.fileTree.items.isEmpty, "A host switch retained the old host's cached rows")
            transport.complete(1, with: .success([.init(name: "second-host.txt", isDirectory: false)]))
            try await waitUntil { !sidebar.fileTree.isRemoteLoading }
            try check(sidebar.fileTree.items.map(\.name) == ["second-host.txt"], "The new host's listing was lost")
            transport.automaticallyComplete([remoteRoot: [.init(name: "second-host.txt", isDirectory: false)]])
            sidebar.refresh()
            try await waitUntil {
                !sidebar.fileTree.isRemoteLoading && sidebar.fileTree.items.map(\.name) == ["second-host.txt"]
            }
        case "remote-stable":
            let folder = sidebar.fileTree.items.first { $0.isDirectory }!
            sidebar.fileTree.toggle(folder)
            try await waitUntil { transport.requestCount == 2 }
            transport.complete(1, with: .success([.init(name: "child.txt", isDirectory: false)]))
            try await waitUntil { !sidebar.fileTree.isRemoteLoading }
            transport.automaticallyComplete([
                remoteRoot: [.init(name: "folder", isDirectory: true), .init(name: "remote.txt", isDirectory: false)],
                folder.path: [.init(name: "child.txt", isDirectory: false)],
            ])
            sidebar.manager.selectedProject = project(root: remoteRoot, endpoint: endpointA, remote: true)
            sidebar.refresh()
            try await waitUntil {
                !sidebar.fileTree.isRemoteLoading && sidebar.fileTree.items.contains { $0.name == "child.txt" }
            }
            try check(sidebar.fileTree.isExpanded(folder)
                      && sidebar.fileTree.items.contains { $0.name == "child.txt" && $0.depth == 1 },
                      "An unchanged remote selection collapsed its expanded rows")
        case "late-local-success", "late-local-failure", "late-empty-success", "late-empty-failure":
            let local = project(root: localRoot.path)
            if scenario.hasPrefix("late-empty") { local.sessions = [] }
            sidebar.manager.selectedProject = local
            sidebar.refresh()
            if scenario.hasPrefix("late-empty") { try await checkEmpty() } else { try await checkLocal() }
            let items = sidebar.fileTree.items
            let root = sidebar.fileTree.rootPath
            if scenario.hasSuffix("success") {
                transport.complete(0, with: .success([.init(name: "stale-remote.txt", isDirectory: false)]))
            } else {
                transport.complete(0, with: .failure(FixtureFailure.failed("Stale SSH failure")))
            }
            try await waitUntil { transport.returnedCount == 1 }
            try await settle()
            try check(sidebar.fileTree.items == items && sidebar.fileTree.rootPath == root
                      && sidebar.fileTree.remoteError == nil && !sidebar.fileTree.isRemoteLoading,
                      "A late remote result changed the local or empty selection")
        default:
            throw FixtureFailure.failed("Unknown regression scenario: \(scenario)")
        }
        try await settle()
        if scenario == "remote-switch" {
            for index in 1..<transport.requestCount {
                let request = transport.request(at: index)
                try check(request.endpoint == endpointB && request.directory == remoteRoot,
                          "A repeated refresh returned to the previous SSH target")
            }
        } else if scenario == "remote-stable" {
            for index in 0..<transport.requestCount {
                let request = transport.request(at: index)
                try check(request.endpoint == endpointA
                          && [remoteRoot, remoteRoot + "/folder"].contains(request.directory),
                          "A repeated refresh changed its SSH target or root")
            }
        } else {
            try check(transport.requestCount == 1, "Local or empty refresh issued an unexpected SSH listing")
        }
        print("\(scenario): passed")
    }
}
