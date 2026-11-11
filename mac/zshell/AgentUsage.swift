//
//  AgentUsage.swift
//  zshell
//

import Combine
import Darwin
import Foundation

enum AgentUsageWindowKind: String, Sendable {
    case fiveHour
    case sevenDay
    case spend
    case primary
    case secondary
}

struct AgentUsageWindow: Equatable, Sendable {
    let kind: AgentUsageWindowKind
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
}

struct AgentUsageSnapshot: Equatable, Sendable {
    let windows: [AgentUsageWindow]
    let plan: String?
    let updatedAt: Date
}

enum AgentUsageAvailability: Equatable, Sendable {
    case disabled
    case waiting
    case available(AgentUsageSnapshot)
    case stale(AgentUsageSnapshot, AgentUsageIssue)
    case unavailable(AgentUsageIssue)
}

enum AgentUsageIssue: String, Error, Equatable, Sendable {
    case cliMissing
    case notSignedIn
    case noClaudeSession
    case noLimits
    case timedOut
    case invalidResponse
    case failed
}

struct AgentUsageProviderState: Equatable, Sendable {
    let kind: ZshellAgentKind
    var availability: AgentUsageAvailability = .disabled
    var isRefreshing = false
}

@MainActor
final class AgentUsageModel: ObservableObject {
    typealias Loader = @Sendable () -> Result<AgentUsageSnapshot, AgentUsageIssue>

    static let shared: AgentUsageModel = {
        let model = AgentUsageModel()
        model.applySettings(AppSettings.shared)
        return model
    }()

    @Published private(set) var claude = AgentUsageProviderState(kind: .claude)
    @Published private(set) var codex = AgentUsageProviderState(kind: .codex)

    private static let freshnessInterval: TimeInterval = 120
    private let claudeLoader: Loader
    private let codexLoader: Loader
    private var claudeEnabled = false
    private var codexEnabled = false
    private var claudeRefresh = Date.distantPast
    private var codexRefresh = Date.distantPast
    private var claudeGeneration: UInt64 = 0
    private var codexGeneration: UInt64 = 0
    private var claudeTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?

    init(
        claudeLoader: Loader? = nil,
        codexLoader: Loader? = nil
    ) {
        self.claudeLoader = claudeLoader ?? { ClaudeUsageStore.load() }
        self.codexLoader = codexLoader ?? { CodexUsageReader.load() }
    }

    func applySettings(_ settings: AppSettings) {
        let nextClaude = settings.agentUsageEnabled && settings.claudeUsageEnabled
        let nextCodex = settings.agentUsageEnabled && settings.codexUsageEnabled
        if nextClaude != claudeEnabled {
            claudeEnabled = nextClaude
            claudeGeneration &+= 1
            claudeTask?.cancel()
            claudeTask = nil
            claude = AgentUsageProviderState(kind: .claude)
            if nextClaude { refreshClaude() }
        }
        if nextCodex != codexEnabled {
            codexEnabled = nextCodex
            codexGeneration &+= 1
            codexTask?.cancel()
            codexTask = nil
            codex = AgentUsageProviderState(kind: .codex)
            if nextCodex { refreshCodex() }
        }
    }

    func refreshIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(claudeRefresh) >= Self.freshnessInterval { refreshClaude() }
        if now.timeIntervalSince(codexRefresh) >= Self.freshnessInterval { refreshCodex() }
    }

    func refresh() {
        refreshClaude()
        refreshCodex()
    }

    func acceptClaudeStatusLine(_ value: ZshellJSONValue) -> Bool {
        guard claudeEnabled,
              let object = value.objectValue,
              let windowsObject = object["windows"]?.objectValue
        else { return false }

        let now = Date()
        let windows: [AgentUsageWindow] = [
            Self.claudeWindow(.fiveHour, key: "five_hour", from: windowsObject, now: now),
            Self.claudeWindow(.sevenDay, key: "seven_day", from: windowsObject, now: now),
            Self.claudeWindow(.spend, key: "spend_limit", from: windowsObject, now: now),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return false }

        let snapshot = AgentUsageSnapshot(windows: windows, plan: nil, updatedAt: now)
        guard ClaudeUsageStore.save(snapshot) else { return false }
        // A live report is newer than any file read that is still finishing.
        claudeGeneration &+= 1
        claudeTask?.cancel()
        claudeTask = nil
        claudeRefresh = now
        claude.isRefreshing = false
        claude.availability = .available(snapshot)
        return true
    }

    private func refreshClaude() {
        guard claudeEnabled, !claude.isRefreshing else { return }
        claudeRefresh = Date()
        claude.isRefreshing = true
        if case .disabled = claude.availability { claude.availability = .waiting }
        claudeGeneration &+= 1
        let generation = claudeGeneration
        let prior = claude.availability
        let loader = claudeLoader
        claudeTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = loader()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.claudeEnabled, self.claudeGeneration == generation else { return }
                self.claudeTask = nil
                self.claude.isRefreshing = false
                self.apply(result, prior: prior, to: &self.claude)
            }
        }
    }

    private func refreshCodex() {
        guard codexEnabled, !codex.isRefreshing else { return }
        codexRefresh = Date()
        codex.isRefreshing = true
        if case .disabled = codex.availability { codex.availability = .waiting }
        codexGeneration &+= 1
        let generation = codexGeneration
        let prior = codex.availability
        let loader = codexLoader
        codexTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = loader()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.codexEnabled, self.codexGeneration == generation else { return }
                self.codexTask = nil
                self.codex.isRefreshing = false
                self.apply(result, prior: prior, to: &self.codex)
            }
        }
    }

    private func apply(
        _ result: Result<AgentUsageSnapshot, AgentUsageIssue>,
        prior: AgentUsageAvailability,
        to state: inout AgentUsageProviderState
    ) {
        switch result {
        case .success(let snapshot):
            state.availability = .available(snapshot)
        case .failure(let issue):
            if case .available(let snapshot) = prior {
                state.availability = .stale(snapshot, issue)
            } else if case .stale(let snapshot, _) = prior {
                state.availability = .stale(snapshot, issue)
            } else {
                state.availability = .unavailable(issue)
            }
        }
    }

    private static func claudeWindow(
        _ kind: AgentUsageWindowKind,
        key: String,
        from object: [String: ZshellJSONValue],
        now: Date
    ) -> AgentUsageWindow? {
        guard let window = object[key]?.objectValue,
              case .number(let percent)? = window["used_percentage"],
              percent.isFinite, percent >= 0
        else { return nil }
        let resetsAt = window["resets_at"].flatMap { value -> Date? in
            guard case .number(let epoch) = value, epoch.isFinite else { return nil }
            return Date(timeIntervalSince1970: epoch)
        }
        if let resetsAt, resetsAt <= now { return nil }
        return AgentUsageWindow(
            kind: kind,
            usedPercent: percent,
            durationMinutes: nil,
            resetsAt: resetsAt
        )
    }
}

// `nonisolated` opts these helpers out of the target's MainActor default
// isolation, so the detached refresh tasks and the status-line CLI can call
// them synchronously without hopping to the main actor.
private nonisolated enum ClaudeUsageStore {
    private struct FileSnapshot: Codable {
        let fiveHour: FileWindow?
        let sevenDay: FileWindow?
        let spendLimit: FileWindow?
        let capturedAt: Date
    }

    private struct FileWindow: Codable {
        let usedPercentage: Double
        let resetsAt: Date?
    }

    private static var fileURL: URL {
        let root = ProcessInfo.processInfo.environment["ZSHELL_CLAUDE_USAGE_FILE"]
            .map { URL(fileURLWithPath: $0) }
            ?? AgentUsagePaths.claudeStatusLineURL
        return root
    }

    static func save(_ snapshot: AgentUsageSnapshot) -> Bool {
        let stored = FileSnapshot(
            fiveHour: fileWindow(.fiveHour, from: snapshot),
            sevenDay: fileWindow(.sevenDay, from: snapshot),
            spendLimit: fileWindow(.spend, from: snapshot),
            capturedAt: snapshot.updatedAt
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    static func load(now: Date = Date()) -> Result<AgentUsageSnapshot, AgentUsageIssue> {
        guard !Task.isCancelled,
              let text = try? SettingsConfigFile.read(at: fileURL),
              !Task.isCancelled,
              let stored = try? JSONDecoder().decode(FileSnapshot.self, from: Data(text.utf8))
        else { return .failure(.noClaudeSession) }

        let windows: [AgentUsageWindow] = [
            window(.fiveHour, stored.fiveHour, now: now),
            window(.sevenDay, stored.sevenDay, now: now),
            window(.spend, stored.spendLimit, now: now),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return .failure(.noLimits) }
        return .success(AgentUsageSnapshot(
            windows: windows,
            plan: nil,
            updatedAt: stored.capturedAt
        ))
    }

    private static func fileWindow(
        _ kind: AgentUsageWindowKind,
        from snapshot: AgentUsageSnapshot
    ) -> FileWindow? {
        guard let window = snapshot.windows.first(where: { $0.kind == kind }) else {
            return nil
        }
        return FileWindow(
            usedPercentage: window.usedPercent,
            resetsAt: window.resetsAt
        )
    }

    private static func window(
        _ kind: AgentUsageWindowKind,
        _ source: FileWindow?,
        now: Date
    ) -> AgentUsageWindow? {
        guard let source, source.usedPercentage.isFinite, source.usedPercentage >= 0 else {
            return nil
        }
        if let reset = source.resetsAt, reset <= now { return nil }
        return AgentUsageWindow(
            kind: kind,
            usedPercent: source.usedPercentage,
            durationMinutes: nil,
            resetsAt: source.resetsAt
        )
    }
}

nonisolated enum AgentUsagePaths {
    static let applicationSupportDirectory: URL = {
        #if DEBUG
        let directory = "zshell-dev"
        #else
        let directory = "zshell"
        #endif
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(directory, isDirectory: true)
    }()

    static var claudeStatusLineURL: URL {
        applicationSupportDirectory.appendingPathComponent("claude-rate-limits.json")
    }
}

private nonisolated enum CodexUsageReader {
    private struct RPCRequest<Parameters: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: Parameters
    }

    private struct InitializeParameters: Encodable {
        let clientInfo = ClientInfo()

        struct ClientInfo: Encodable {
            let name = "zshell"
            let title = "Zshell"
            let version = "1"
        }
    }

    private struct RateLimitParameters: Encodable {
        let excludeResetCreditDetails = true
    }

    private struct RPCResponse: Decodable {
        let id: Int?
        let result: RateLimitResponse?
        let error: RPCError?
    }

    private struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    private struct RateLimitResponse: Decodable {
        let rateLimits: RateLimitSnapshot
    }

    private struct RateLimitSnapshot: Decodable {
        let planType: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    private enum ReadResult {
        case response(RateLimitResponse)
        case error(AgentUsageIssue)
        case noResponse
    }

    static func load() -> Result<AgentUsageSnapshot, AgentUsageIssue> {
        guard !Task.isCancelled else { return .failure(.failed) }
        guard let executable = resolveExecutable("codex") else {
            return .failure(.cliMissing)
        }

        let encoder = JSONEncoder()
        guard let initialize = try? encoder.encode(RPCRequest(
            id: 1,
            method: "initialize",
            params: InitializeParameters()
        )), let limits = try? encoder.encode(RPCRequest(
            id: 2,
            method: "account/rateLimits/read",
            params: RateLimitParameters()
        )) else { return .failure(.failed) }

        let command = ProcessRunner.run(
            executable: executable,
            arguments: ["app-server", "--listen", "stdio://"],
            initialInput: initialize,
            initializedInput: Data("{\"method\":\"initialized\",\"params\":{}}".utf8),
            secondInput: limits,
            waitForResponseID: 1,
            secondResponseID: 2,
            timeout: 8
        )
        guard !Task.isCancelled else { return .failure(.failed) }
        if command.timedOut { return .failure(.timedOut) }

        switch response(from: command.stdout) {
        case .response(let response):
            let snapshot = snapshot(from: response)
            return snapshot.windows.isEmpty ? .failure(.noLimits) : .success(snapshot)
        case .error(let issue):
            return .failure(issue)
        case .noResponse:
            return .failure(command.status == 0 ? .invalidResponse : .failed)
        }
    }

    private static func response(from data: Data) -> ReadResult {
        for line in data.split(separator: 0x0A) {
            guard let response = try? JSONDecoder().decode(RPCResponse.self, from: line),
                  response.id == 2
            else { continue }
            if let result = response.result { return .response(result) }
            guard let error = response.error else { return .error(.invalidResponse) }
            if error.message.localizedCaseInsensitiveContains("authentication required") {
                return .error(.notSignedIn)
            }
            return .error(error.code == -32600 ? .failed : .invalidResponse)
        }
        return .noResponse
    }

    private static func snapshot(from response: RateLimitResponse) -> AgentUsageSnapshot {
        let limits = response.rateLimits
        return AgentUsageSnapshot(
            windows: [
                window(.primary, limits.primary),
                window(.secondary, limits.secondary),
            ].compactMap { $0 },
            plan: limits.planType,
            updatedAt: Date()
        )
    }

    private static func window(
        _ kind: AgentUsageWindowKind,
        _ source: RateLimitWindow?
    ) -> AgentUsageWindow? {
        guard let source, source.usedPercent >= 0 else { return nil }
        let reset = source.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
        if let reset, reset <= Date() { return nil }
        return AgentUsageWindow(
            kind: kind,
            usedPercent: Double(source.usedPercent),
            durationMinutes: source.windowDurationMins,
            resetsAt: reset
        )
    }

    private static func resolveExecutable(_ name: String) -> URL? {
        ProcessRunner.resolveExecutable(name)
    }
}

nonisolated struct ProcessCommandResult {
    let stdout: Data
    let status: Int32
    let timedOut: Bool
}

nonisolated enum ProcessRunner {
    static func resolveExecutable(
        _ name: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Empty entries conventionally mean "the current directory"; the app
        // must never execute from an arbitrary working directory, so skip them.
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate.path)
            else { continue }
            return candidate
        }
        return nil
    }
    private struct ResponseEnvelope: Decodable {
        let id: Int?
    }

    private final class PipeData: @unchecked Sendable {
        private static let maximumBytes = 1_048_576
        private let lock = NSLock()
        private var storage = Data()
        private var sawResponse = false
        private var sawSecondResponse = false
        private var stopped = false
        private let responseID: Int?
        private let secondResponseID: Int?
        let responseReady = DispatchSemaphore(value: 0)
        let secondResponseReady = DispatchSemaphore(value: 0)

        init(responseID: Int? = nil, secondResponseID: Int? = nil) {
            self.responseID = responseID
            self.secondResponseID = secondResponseID
        }

        func append(_ data: Data) {
            lock.lock()
            let remaining = max(Self.maximumBytes - storage.count, 0)
            if remaining > 0 { storage.append(data.prefix(remaining)) }
            if !sawResponse, let responseID,
               storage.split(separator: 0x0A).contains(where: {
                   (try? JSONDecoder().decode(ResponseEnvelope.self, from: $0))?.id == responseID
               }) {
                sawResponse = true
                responseReady.signal()
            }
            if !sawSecondResponse, let secondResponseID,
               storage.split(separator: 0x0A).contains(where: {
                   (try? JSONDecoder().decode(ResponseEnvelope.self, from: $0))?.id == secondResponseID
               }) {
                sawSecondResponse = true
                secondResponseReady.signal()
            }
            lock.unlock()
        }

        func finish() {
            lock.lock()
            if !sawResponse { responseReady.signal() }
            if !sawSecondResponse { secondResponseReady.signal() }
            lock.unlock()
        }

        var didSeeResponse: Bool {
            lock.withLock { sawResponse }
        }

        var value: Data {
            lock.withLock { storage }
        }

        var isStopped: Bool { lock.withLock { stopped } }

        func stop() { lock.withLock { stopped = true } }
    }

    static func run(
        executable: URL,
        arguments: [String],
        initialInput: Data,
        initializedInput: Data,
        secondInput: Data,
        waitForResponseID: Int,
        secondResponseID: Int,
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) -> ProcessCommandResult {
        guard !Task.isCancelled else {
            return ProcessCommandResult(stdout: Data(), status: -2, timedOut: false)
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            guard !Task.isCancelled else {
                return ProcessCommandResult(stdout: Data(), status: -2, timedOut: false)
            }
            try process.run()
        } catch {
            return ProcessCommandResult(stdout: Data(), status: -1, timedOut: false)
        }

        let stdoutData = PipeData(
            responseID: waitForResponseID,
            secondResponseID: secondResponseID
        )
        let stderrData = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        let stdoutReader = Thread {
            read(stdout.fileHandleForReading, into: stdoutData)
            stdoutData.finish()
            readers.leave()
        }
        stdoutReader.qualityOfService = .utility
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            read(stderr.fileHandleForReading, into: stderrData)
            readers.leave()
        }
        stderrReader.qualityOfService = .utility
        stderrReader.start()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        do {
            // The CLI can exit while a request is being written.
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw POSIXError(.EIO)
            }
            try Task.checkCancellation()
            var first = initialInput
            first.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: first)
            if !wait(stdoutData.responseReady, until: deadline) {
                timedOut = !Task.isCancelled
            } else if stdoutData.didSeeResponse {
                try Task.checkCancellation()
                var initialized = initializedInput
                initialized.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: initialized)
                try Task.checkCancellation()
                var second = secondInput
                second.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: second)
                if !wait(stdoutData.secondResponseReady, until: deadline) {
                    timedOut = !Task.isCancelled
                }
            }
            try stdin.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
        }
        try? stdin.fileHandleForWriting.close()

        if !timedOut, !Task.isCancelled {
            timedOut = !wait(completed, until: deadline)
        }
        if (timedOut || Task.isCancelled), process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        if readers.wait(timeout: .now() + 1) == .timedOut {
            stdoutData.stop()
            stderrData.stop()
            _ = readers.wait(timeout: .now() + 0.25)
        }
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        return ProcessCommandResult(
            stdout: stdoutData.value,
            status: timedOut || Task.isCancelled ? -2 : process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func wait(_ semaphore: DispatchSemaphore, until deadline: Date) -> Bool {
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            if semaphore.wait(timeout: .now() + min(remaining, 0.05)) == .success {
                return !Task.isCancelled
            }
        }
        return false
    }

    private static func read(_ handle: FileHandle, into data: PipeData) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while !data.isStopped {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = Darwin.poll(&ready, 1, 50)
            if status == 0 || status < 0 && errno == EINTR { continue }
            guard status > 0 else { return }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { data.append(Data(buffer.prefix(count))) }
            else if count == 0 { return }
            else if errno != EINTR && errno != EAGAIN { return }
        }
    }
}
