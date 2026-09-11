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
    var availability: AgentUsageAvailability = .waiting
    var isRefreshing = false
}

@MainActor
final class AgentUsageModel: ObservableObject {
    static let shared = AgentUsageModel()

    @Published private(set) var claude = AgentUsageProviderState(kind: .claude)
    @Published private(set) var codex = AgentUsageProviderState(kind: .codex)

    private static let freshnessInterval: TimeInterval = 120
    private var lastRefresh = Date.distantPast

    private init() {}

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) >= Self.freshnessInterval else { return }
        refresh()
    }

    func refresh() {
        lastRefresh = Date()
        refreshClaude()
        refreshCodex()
    }

    func acceptClaudeStatusLine(_ value: ZshellJSONValue) -> Bool {
        guard let object = value.objectValue,
              let windowsObject = object["windows"]?.objectValue
        else { return false }

        let now = Date()
        let windows: [AgentUsageWindow] = [
            Self.claudeWindow(.fiveHour, key: "five_hour", from: windowsObject, now: now),
            Self.claudeWindow(.sevenDay, key: "seven_day", from: windowsObject, now: now),
            Self.claudeWindow(.spend, key: "spend_limit", from: windowsObject, now: now),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return false }

        let snapshot = AgentUsageSnapshot(
            windows: windows,
            plan: nil,
            updatedAt: now
        )
        guard ClaudeUsageStore.save(snapshot) else { return false }
        claude.availability = .available(snapshot)
        return true
    }

    private func refreshClaude() {
        guard !claude.isRefreshing else { return }
        claude.isRefreshing = true
        let prior = claude.availability
        Task.detached(priority: .utility) { [prior] in
            let result = ClaudeUsageStore.load()
            await MainActor.run {
                AgentUsageModel.shared.claude.isRefreshing = false
                AgentUsageModel.shared.apply(result, prior: prior, to: &AgentUsageModel.shared.claude)
            }
        }
    }

    private func refreshCodex() {
        guard !codex.isRefreshing else { return }
        codex.isRefreshing = true
        let prior = codex.availability
        Task.detached(priority: .utility) { [prior] in
            let result = CodexUsageReader.load()
            await MainActor.run {
                AgentUsageModel.shared.codex.isRefreshing = false
                AgentUsageModel.shared.apply(result, prior: prior, to: &AgentUsageModel.shared.codex)
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
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(FileSnapshot.self, from: data)
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
            secondInput: limits,
            waitForResponseID: 1,
            timeout: 8
        )
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
        let environment = ProcessInfo.processInfo.environment
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
}

private nonisolated struct ProcessCommandResult {
    let stdout: Data
    let status: Int32
    let timedOut: Bool
}

private nonisolated enum ProcessRunner {
    private struct ResponseEnvelope: Decodable {
        let id: Int?
    }

    private final class PipeData: @unchecked Sendable {
        private static let maximumBytes = 1_048_576
        private let lock = NSLock()
        private var storage = Data()
        private var sawResponse = false
        private let responseID: Int?
        let responseReady = DispatchSemaphore(value: 0)

        init(responseID: Int? = nil) {
            self.responseID = responseID
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
            lock.unlock()
        }

        func finish() {
            lock.lock()
            if !sawResponse { responseReady.signal() }
            lock.unlock()
        }

        var didSeeResponse: Bool {
            lock.withLock { sawResponse }
        }

        var value: Data {
            lock.withLock { storage }
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        initialInput: Data,
        secondInput: Data,
        waitForResponseID: Int,
        timeout: TimeInterval
    ) -> ProcessCommandResult {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return ProcessCommandResult(stdout: Data(), status: -1, timedOut: false)
        }

        let stdoutData = PipeData(responseID: waitForResponseID)
        let stderrData = PipeData()
        let readers = DispatchGroup()
        readers.enter()
        let stdoutReader = Thread {
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                stdoutData.append(data)
            }
            stdoutData.finish()
            readers.leave()
        }
        stdoutReader.qualityOfService = .utility
        stdoutReader.start()
        readers.enter()
        let stderrReader = Thread {
            stderrData.append(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        stderrReader.qualityOfService = .utility
        stderrReader.start()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        do {
            var first = initialInput
            first.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: first)
            let wait = max(deadline.timeIntervalSinceNow, 0)
            if stdoutData.responseReady.wait(timeout: .now() + wait) == .timedOut {
                timedOut = true
            } else if stdoutData.didSeeResponse {
                var second = secondInput
                second.append(0x0A)
                try stdin.fileHandleForWriting.write(contentsOf: second)
            }
            try stdin.fileHandleForWriting.close()
        } catch {
            process.terminate()
        }

        if !timedOut {
            let wait = max(deadline.timeIntervalSinceNow, 0)
            timedOut = completed.wait(timeout: .now() + wait) == .timedOut
        }
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        readers.wait()
        _ = stderrData.value
        return ProcessCommandResult(
            stdout: stdoutData.value,
            status: timedOut ? -2 : process.terminationStatus,
            timedOut: timedOut
        )
    }
}
