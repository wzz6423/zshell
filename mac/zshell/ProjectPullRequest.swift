import Combine
import Darwin
import Foundation

nonisolated struct GitHubRepository: Hashable, Sendable {
    let nameWithOwner: String

    init?(_ nameWithOwner: String) {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }),
              !parts.contains("."), !parts.contains("..") else { return nil }
        self.nameWithOwner = nameWithOwner.lowercased()
    }

    static func remote(_ value: String) -> GitHubRepository? {
        guard value.count <= 4_096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let path: String
        if let components = URLComponents(string: value),
           let scheme = components.scheme, ["https", "http", "ssh", "git"].contains(scheme),
           let host = components.host?.lowercased(), ["github.com", "ssh.github.com"].contains(host),
           components.query == nil, components.fragment == nil {
            path = components.path
        } else if let colon = value.firstIndex(of: ":") {
            let host = value[..<colon].split(separator: "@").last?.lowercased()
            guard host == "github.com" else { return nil }
            path = String(value[value.index(after: colon)...])
        } else { return nil }
        var name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if name.hasSuffix(".git") { name.removeLast(4) }
        return GitHubRepository(name)
    }
}

nonisolated struct ProjectPullRequest: Equatable, Sendable {
    enum Status: String, Sendable {
        case open = "OPEN", draft = "DRAFT", merged = "MERGED", closed = "CLOSED"

        var label: String {
            switch self {
            case .open: String(localized: "Open PR")
            case .draft: String(localized: "Draft PR")
            case .merged: String(localized: "Merged PR")
            case .closed: String(localized: "Closed PR")
            }
        }
    }

    let number: Int
    let status: Status
    let url: URL
}

nonisolated enum ProjectPullRequestState: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case missingCLI, notSignedIn, unavailable, ambiguousRemote

        var message: String {
            switch self {
            case .missingCLI: String(localized: "Install GitHub CLI (gh).")
            case .notSignedIn: String(localized: "Sign in with gh auth login.")
            case .unavailable: String(localized: "Check your connection and refresh.")
            case .ambiguousRemote: String(localized: "Set the branch upstream or a default GitHub remote.")
            }
        }
    }

    case hidden, loading, none
    case pullRequest(ProjectPullRequest)
    case failed(Failure)

    var label: String {
        switch self {
        case .hidden: ""
        case .loading: String(localized: "Checking PR…")
        case .none: String(localized: "No PR")
        case .pullRequest(let pr): "#\(pr.number) · \(pr.status.label)"
        case .failed: String(localized: "PR unavailable")
        }
    }

    var help: String {
        switch self {
        case .failed(let failure): failure.message
        default: label
        }
    }
}

nonisolated struct ProjectPullRequestContext: Hashable, Sendable {
    let root: String
    let gitDirectory: String
    let localBranch: String
    let headBranch: String
    let headRepository: GitHubRepository
    let baseRepository: GitHubRepository?

    enum Resolution: Sendable {
        case context(ProjectPullRequestContext), hidden, ambiguous
    }

    static func resolve(_ snapshot: GitStatusModel.BranchSnapshot) -> Resolution {
        guard let branch = snapshot.branch, !branch.isEmpty else { return .hidden }
        let config = snapshot.configuration
        func value(_ key: String) -> String? { config[key]?.last }
        let names = config.keys.filter { $0.hasPrefix("remote.") && $0.hasSuffix(".url") }
            .map { String($0.dropFirst(7).dropLast(4)) }.sorted()
        guard !names.isEmpty else { return .hidden }
        func repository(_ remote: String) -> GitHubRepository? {
            config["remote.\(remote).url"]?.first.flatMap(GitHubRepository.remote)
        }
        let tracking = value("branch.\(branch).remote")
        let push = value("branch.\(branch).pushremote") ?? value("remote.pushdefault")
        let resolved = names.filter { value("remote.\($0).gh-resolved") == "base" }
        guard resolved.count <= 1 else { return .ambiguous }
        let headRemote: String
        if let selected = push ?? tracking, selected != "." {
            headRemote = selected
        } else if names.contains("origin") {
            headRemote = "origin"
        } else if names.count == 1 {
            headRemote = names[0]
        } else if Set(names.compactMap(repository)).count == 1,
                  names.allSatisfy({ repository($0) != nil }) {
            headRemote = names[0]
        } else { return .ambiguous }
        guard let headRepository = repository(headRemote) else { return .hidden }
        let base: GitHubRepository?
        if let name = resolved.first {
            guard let selected = repository(name) else { return .hidden }
            base = selected
        } else {
            base = names.contains("upstream") ? repository("upstream") : nil
        }
        let merge = value("branch.\(branch).merge")
        let headBranch = push == nil && headRemote == tracking && merge?.hasPrefix("refs/heads/") == true
            ? String(merge!.dropFirst("refs/heads/".count)) : branch
        return .context(ProjectPullRequestContext(root: snapshot.root, gitDirectory: snapshot.gitDirectory,
            localBranch: branch, headBranch: headBranch, headRepository: headRepository, baseRepository: base))
    }
}

nonisolated enum GitHubPullRequestWorker {
    typealias Command = @Sendable (URL, [String], TimeInterval, [String: String]) throws -> BoundedProcessResult
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "sh.zshell.pull-requests"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func lookup(_ context: ProjectPullRequestContext) async -> ProjectPullRequestState {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: query(context)) }
        }
    }

    static func query(
        _ context: ProjectPullRequestContext,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locate: @Sendable ([String: String]) -> URL? = { ProcessRunner.resolveExecutable("gh", environment: $0) },
        command: Command = {
            try BoundedProcessRunner.run(executableURL: $0, arguments: $1, timeout: $2,
                                         outputLimit: 262_144, environment: $3)
        }
    ) -> ProjectPullRequestState {
        var environment = environment
        let path = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
        environment["PATH"] = (path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        for key in ["GH_DEBUG", "GH_REPO", "ZSHELL_CLI_STATE", "ZSHELL_CLI_TOKEN"] { environment.removeValue(forKey: key) }
        environment["GH_HOST"] = "github.com"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "/bin/cat"
        guard let executable = locate(environment) else { return .failed(.missingCLI) }
        let deadline = Date().addingTimeInterval(12)
        func load(_ repository: GitHubRepository) throws -> RepositoryResponse.Repository {
            let parts = repository.nameWithOwner.split(separator: "/")
            let result = try command(executable, ["api", "graphql", "--hostname", "github.com",
                "-f", "query=" + queryText, "-f", "owner=" + parts[0], "-f", "name=" + parts[1],
                "-f", "branch=" + context.headBranch], max(0, deadline.timeIntervalSinceNow), environment)
            guard !result.timedOut, !result.output.wasTruncated else { throw QueryFailure.unavailable }
            if result.terminationStatus == 4 { throw QueryFailure.notSignedIn }
            guard result.terminationStatus == 0,
                  let response = try? JSONDecoder().decode(RepositoryResponse.self, from: Data(result.output.stdout.utf8)),
                  response.errors?.isEmpty != false, let repository = response.data?.repository else {
                throw QueryFailure.unavailable
            }
            return repository
        }
        do {
            let base = context.baseRepository ?? context.headRepository
            let response = try load(base)
            var candidates = try response.matches(context, in: base)
            if base != context.headRepository {
                candidates += try load(context.headRepository).matches(context, in: context.headRepository)
            } else if context.baseRepository == nil, let parent = response.parent,
               let parentRepository = GitHubRepository(parent.nameWithOwner), parentRepository != base {
                candidates += try load(parentRepository).matches(context, in: parentRepository)
            }
            let selected = candidates.sorted {
                let lhsOpen = $0.state == "OPEN", rhsOpen = $1.state == "OPEN"
                if lhsOpen != rhsOpen { return lhsOpen }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.number > $1.number
            }.first
            guard let selected, let status = ProjectPullRequest.Status(rawValue: selected.state),
                  let url = URL(string: selected.url) else { return .none }
            return .pullRequest(ProjectPullRequest(number: selected.number,
                status: status == .open && selected.isDraft ? .draft : status, url: url))
        } catch QueryFailure.notSignedIn { return .failed(.notSignedIn) }
        catch { return .failed(.unavailable) }
    }

    private enum QueryFailure: Error { case notSignedIn, unavailable }
    private static let queryText = """
        query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,name:$name){
        parent{nameWithOwner} pullRequests(headRefName:$branch,states:[OPEN,MERGED,CLOSED],first:50,
        orderBy:{field:UPDATED_AT,direction:DESC}){pageInfo{hasNextPage} nodes{number url state isDraft
        headRefName headRepository{nameWithOwner} updatedAt}}}}
        """

    private struct RepositoryResponse: Decodable {
        struct Repository: Decodable {
            struct Reference: Decodable { let nameWithOwner: String }
            struct PullRequest: Decodable {
                let number: Int
                let url: String
                let state: String
                let isDraft: Bool
                let headRefName: String
                let headRepository: Reference?
                let updatedAt: String
            }
            struct Connection: Decodable {
                struct PageInfo: Decodable { let hasNextPage: Bool }
                let nodes: [PullRequest]
                let pageInfo: PageInfo
            }
            let parent: Reference?
            let pullRequests: Connection

            func matches(_ context: ProjectPullRequestContext, in base: GitHubRepository) throws -> [PullRequest] {
                // A same-named branch in another fork is not this project's PR.
                let matching = pullRequests.nodes.filter {
                    $0.number > 0 && $0.headRefName == context.headBranch
                        && $0.headRepository.flatMap { GitHubRepository($0.nameWithOwner) } == context.headRepository
                        && ProjectPullRequest.Status(rawValue: $0.state) != nil
                        && $0.url.lowercased() == "https://github.com/\(base.nameWithOwner)/pull/\($0.number)"
                }
                guard !pullRequests.pageInfo.hasNextPage else { throw QueryFailure.unavailable }
                return matching
            }
        }
        struct Payload: Decodable { let repository: Repository? }
        struct Failure: Decodable { let message: String }
        let data: Payload?
        let errors: [Failure]?
    }
}

actor ProjectPullRequestCache {
    static let shared = ProjectPullRequestCache()
    typealias Lookup = @Sendable (ProjectPullRequestContext) async -> ProjectPullRequestState
    private struct Entry {
        let state: ProjectPullRequestState
        let expires: Date
        var used: Date
    }
    private struct Pending { let id: UUID; let task: Task<ProjectPullRequestState, Never> }
    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private let capacity: Int
    private var entries: [ProjectPullRequestContext: Entry] = [:]
    private var pending: [ProjectPullRequestContext: Pending] = [:]

    init(capacity: Int = 64, now: @escaping @Sendable () -> Date = { Date() },
         lookup: @escaping Lookup = { await GitHubPullRequestWorker.lookup($0) }) {
        self.capacity = max(1, capacity)
        self.now = now
        self.lookup = lookup
    }

    func value(for context: ProjectPullRequestContext, force: Bool = false) async -> ProjectPullRequestState {
        let date = now()
        if force { entries[context] = nil }
        if var cached = entries[context], cached.expires > date {
            cached.used = date
            entries[context] = cached
            return cached.state
        }
        let request: Pending
        if let existing = pending[context] { request = existing }
        else {
            guard pending.count < 16 else { return .failed(.unavailable) }
            let lookup = lookup
            request = Pending(id: UUID(), task: Task { await lookup(context) })
            pending[context] = request
        }
        let state = await request.task.value
        if pending[context]?.id == request.id {
            pending[context] = nil
            let lifetime: TimeInterval = if case .failed = state { 15 } else { 60 }
            entries[context] = Entry(state: state, expires: now().addingTimeInterval(lifetime), used: now())
            while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                entries[oldest] = nil
            }
        }
        return state
    }
}

@MainActor
final class ProjectPullRequestModel: ObservableObject {
    @Published private(set) var state: ProjectPullRequestState = .hidden
    private let cache: ProjectPullRequestCache
    private let probe: @Sendable (String) -> GitStatusModel.BranchSnapshotResult
    private let queue = DispatchQueue(label: "sh.zshell.pr-branch", qos: .utility)
    private var directory: String?
    private var snapshot: GitStatusModel.BranchSnapshot?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var generation: UInt = 0
    private var lastProbe = Date.distantPast
    private var lastLookup = Date.distantPast
    private var isProbing = false
    private var refreshPending = false
    private var forceLookupPending = false

    init(cache: ProjectPullRequestCache = .shared,
         probe: @escaping @Sendable (String) -> GitStatusModel.BranchSnapshotResult = { GitStatusModel.branchSnapshot(in: $0) }) {
        self.cache = cache
        self.probe = probe
    }

    isolated deinit { sources.forEach { $0.cancel() } }

    func sync(directory: String?, force: Bool = false) {
        if self.directory != directory {
            generation &+= 1
            self.directory = directory
            snapshot = nil
            state = .hidden
            lastProbe = .distantPast
            lastLookup = .distantPast
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
        guard let directory else { return }
        forceLookupPending = forceLookupPending || force
        guard !isProbing else { refreshPending = true; return }
        guard force || Date().timeIntervalSince(lastProbe) >= 2 else { return }
        isProbing = true
        lastProbe = Date()
        let generation = generation, probe = probe
        queue.async { [weak self] in
            let result = probe(directory)
            Task { @MainActor [weak self] in self?.received(result, generation: generation) }
        }
    }

    func refresh() { sync(directory: directory, force: true) }

    func detach() { sync(directory: nil) }

    func open(_ opener: @escaping (URL) -> Void) {
        guard case .pullRequest(let pr) = state, let expected = snapshot, let directory else { return }
        let generation = generation, probe = probe
        queue.async { [weak self] in
            let result = probe(directory)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      case .repository(let current) = result, current == expected,
                      self.state == .pullRequest(pr) else { self?.invalidate(); return }
                opener(pr.url)
            }
        }
    }

    private func invalidate() {
        generation &+= 1
        state = .hidden
        lastProbe = .distantPast
        lastLookup = .distantPast
        sync(directory: directory)
    }

    private func received(_ result: GitStatusModel.BranchSnapshotResult, generation: UInt) {
        isProbing = false
        guard self.generation == generation else { sync(directory: directory); return }
        switch result {
        case .notRepository:
            state = .hidden
            snapshot = nil
        case .unavailable:
            state = .failed(.unavailable)
            snapshot = nil
        case .repository(let current):
            let changed = current != snapshot
            if changed {
                self.generation &+= 1
                snapshot = current
                watch(current.watchPaths)
                state = .hidden
            }
            switch ProjectPullRequestContext.resolve(current) {
            case .hidden: state = .hidden
            case .ambiguous: state = .failed(.ambiguousRemote)
            case .context(let context):
                if changed || forceLookupPending || Date().timeIntervalSince(lastLookup) >= 60 {
                    lookup(context, snapshot: current, force: forceLookupPending)
                }
            }
        }
        forceLookupPending = false
        if refreshPending { refreshPending = false; lastProbe = .distantPast; sync(directory: directory) }
    }

    private func lookup(_ context: ProjectPullRequestContext, snapshot: GitStatusModel.BranchSnapshot, force: Bool) {
        lastLookup = Date()
        state = .loading
        let generation = generation, cache = cache, probe = probe, queue = queue
        Task { [weak self] in
            let result = await cache.value(for: context, force: force)
            let verified = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: probe(context.root)) }
            }
            guard let self, self.generation == generation else { return }
            guard case .repository(let current) = verified, current == snapshot else { self.invalidate(); return }
            self.state = result
        }
    }

    private func watch(_ paths: [String]) {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for path in paths {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.invalidate() } }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }
}
