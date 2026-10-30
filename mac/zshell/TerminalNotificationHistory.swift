import Combine
import Foundation
import Synchronization

nonisolated struct TerminalNotificationTarget: Codable, Equatable, Sendable {
    let terminalID: UUID?
    var projectID: UUID?
    var tabID: UUID?
    var paneID: UUID?
    var projectName: String?
    var tabName: String?
    var remoteHostID: UUID?
    var remoteSessionID: UUID?
    var remoteHostName: String?

    var sourceKey: String {
        if let remoteHostID, let remoteSessionID { return "remote:\(remoteHostID):\(remoteSessionID)" }
        return terminalID.map { "terminal:\($0)" } ?? "application"
    }
}

nonisolated struct TerminalNotificationRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case terminal, bell, command, agent }

    let id: UUID
    let eventKey: String
    let kind: Kind
    var message: String
    var target: TerminalNotificationTarget
    let createdAt: Date
    var isRead: Bool
    var isFailure: Bool
    var isPending: Bool

    var isValid: Bool {
        !eventKey.isEmpty && eventKey.utf8.count <= 256
            && !message.isEmpty && message.utf8.count <= 2_048
            && AgentConversationHistoryRecord.normalizedText(message, maximumBytes: 2_048) == message
            && createdAt.timeIntervalSince1970.isFinite
            && [target.projectName, target.tabName, target.remoteHostName].allSatisfy {
                $0.map { $0.utf8.count <= 256 && AgentConversationHistoryRecord.normalizedText($0) == $0 } ?? true
            }
    }
}

@MainActor
final class TerminalNotificationHistoryStore: ObservableObject {
    static let maximumRecords = 200
    nonisolated static let maximumBytes = 2_097_152
    nonisolated static let maximumEventKeys = 512
    nonisolated static let maximumEpisodes = 200

    enum Filter: Int, CaseIterable { case all, unread, failed, pending }

    private nonisolated struct AgentEpisode: Codable, Sendable {
        let sourceKey: String
        let signature: String
        let eventKey: String
    }

    private nonisolated struct Snapshot: Codable, Sendable {
        var version = 1
        var records: [TerminalNotificationRecord]
        var eventKeys: [String]
        var episodes: [AgentEpisode]

        init(records: [TerminalNotificationRecord] = [], eventKeys: [String] = [], episodes: [AgentEpisode] = []) {
            self.records = records
            self.eventKeys = eventKeys
            self.episodes = episodes
        }

        private enum CodingKeys: String, CodingKey { case version, records, eventKeys, episodes }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            var list = try values.nestedUnkeyedContainer(forKey: .records)
            guard version == 1, (list.count ?? 0) <= 200 else {
                throw CocoaError(.coderReadCorrupt)
            }
            records = []
            var ids = Set<UUID>()
            var keys = Set<String>()
            while !list.isAtEnd {
                let decoder = try list.superDecoder()
                if let record = try? TerminalNotificationRecord(from: decoder), record.isValid,
                   ids.insert(record.id).inserted, keys.insert(record.eventKey).inserted {
                    records.append(record)
                }
            }
            eventKeys = try values.decode([String].self, forKey: .eventKeys)
            episodes = try values.decode([AgentEpisode].self, forKey: .episodes)
            guard eventKeys.count <= maximumEventKeys, episodes.count <= maximumEpisodes,
                  eventKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
                  episodes.allSatisfy({ $0.sourceKey.utf8.count <= 128 && $0.signature.utf8.count <= 256
                      && !$0.eventKey.isEmpty && $0.eventKey.utf8.count <= 256 }) else {
                throw CocoaError(.coderReadCorrupt)
            }
        }
    }

    private nonisolated final class Persistence: Sendable {
        private struct Pending: Sendable {
            let snapshot: Snapshot
            let completion: @Sendable (String?) -> Void
        }
        private struct State: Sendable {
            var pending: Pending?
            var scheduled = false
            var error: String?
        }

        private let url: URL
        private let queue = DispatchQueue(label: "sh.zshell.notifications.persistence", qos: .utility)
        private let state = Mutex(State())

        init(url: URL) { self.url = url }

        func load(completion: @escaping @Sendable (Snapshot, String?) -> Void) {
            queue.async { [self] in
                do {
                    let parent = url.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try PersistentCLIConnection.preparePrivateDirectory(parent)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        completion(Snapshot(), nil)
                        return
                    }
                    let data = try PersistentCLIConnection.readPrivate(url, maximumBytes: maximumBytes)
                    completion(try JSONDecoder().decode(Snapshot.self, from: data), nil)
                } catch { completion(Snapshot(), String(describing: error)) }
            }
        }

        func enqueue(_ snapshot: Snapshot, completion: @escaping @Sendable (String?) -> Void) {
            let start = state.withLock { state in
                // At most one snapshot waits behind the current write, even
                // when a noisy PTY produces notifications faster than disk I/O.
                state.pending = Pending(snapshot: snapshot, completion: completion)
                guard !state.scheduled else { return false }
                state.scheduled = true
                return true
            }
            guard start else { return }
            queue.async { [self] in
                while let pending = state.withLock({ state -> Pending? in
                    let next = state.pending
                    state.pending = nil
                    if next == nil { state.scheduled = false }
                    return next
                }) {
                    var error: String?
                    do {
                        try PersistentCLIConnection.verifyPrivateDirectory(url.deletingLastPathComponent())
                        let data = try JSONEncoder().encode(pending.snapshot)
                        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                        try PersistentCLIConnection.writePrivate(data, to: url, durable: true)
                    } catch let failure { error = String(describing: failure) }
                    state.withLock { $0.error = error }
                    pending.completion(error)
                }
            }
        }

        func flush(completion: @escaping @Sendable (String?) -> Void) {
            queue.async { [self] in completion(state.withLock { $0.error }) }
        }
    }

    @Published private(set) var records: [TerminalNotificationRecord] = []
    @Published private(set) var isLoading = true
    @Published private(set) var persistenceError: String?
    var onLoaded: (() -> Void)?
    private var eventKeys: [String] = []
    private var episodes: [AgentEpisode] = []
    private let persistence: Persistence
    private var generation: UInt64 = 0
    private var ignoredLoadedRecords = false
    private var markedLoadedRecordsRead = false
    private var removedWhileLoading = Set<String>()
    private var restoredEventKeys = Set<String>()
    private var loadingWaiters: [CheckedContinuation<Void, Never>] = []

    init(url: URL? = nil) {
        #if DEBUG
        let directory = "zshell-dev"
        #else
        let directory = "zshell"
        #endif
        let url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(directory)/notifications/records.json")
        persistence = Persistence(url: url)
        persistence.load { [weak self] saved, error in
            Task { @MainActor [weak self] in self?.loaded(saved, error: error) }
        }
    }

    private func loaded(_ saved: Snapshot, error: String?) {
        restoredEventKeys = Set(saved.eventKeys)
        let savedByKey = Dictionary(saved.records.map { ($0.eventKey, $0) }, uniquingKeysWith: { first, _ in first })
        let current = records.filter {
            !restoredEventKeys.contains($0.eventKey) || !ignoredLoadedRecords && savedByKey[$0.eventKey] != nil
        }.map { record -> TerminalNotificationRecord in
            guard let saved = savedByKey[record.eventKey] else { return record }
            var merged = saved
            merged.target = record.target
            merged.isRead = saved.isRead || record.isRead
            merged.isPending = record.isPending
            return merged
        }
        var seen = Set(current.map(\.eventKey))
        var combined = current
        if !ignoredLoadedRecords {
            for var record in saved.records where !removedWhileLoading.contains(record.eventKey)
                && seen.insert(record.eventKey).inserted {
                if markedLoadedRecordsRead { record.isRead = true }
                combined.append(record)
            }
        }
        records = Array(combined.sorted { $0.createdAt > $1.createdAt }.prefix(Self.maximumRecords))
        eventKeys = uniqueSuffix(saved.eventKeys + eventKeys, maximum: Self.maximumEventKeys)
        let currentSources = Set(episodes.map(\.sourceKey))
        episodes = Array((saved.episodes.filter { !currentSources.contains($0.sourceKey) } + episodes).suffix(Self.maximumEpisodes))
        removedWhileLoading.removeAll()
        persistenceError = error
        isLoading = false
        onLoaded?()
        if generation > 0 { persist() }
        let waiters = loadingWaiters
        loadingWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func filtered(_ filter: Filter) -> [TerminalNotificationRecord] {
        records.filter {
            switch filter {
            case .all: true
            case .unread: !$0.isRead
            case .failed: $0.isFailure
            case .pending: $0.isPending
            }
        }
    }

    func record(id: UUID) -> TerminalNotificationRecord? { records.first { $0.id == id } }

    func wasRestored(eventKey: String) -> Bool { restoredEventKeys.contains(eventKey) }

    /// The last actionable episode survives relaunch and clearing the list.
    /// Replaying a remote generation or reconnecting the same local agent must
    /// not turn a dismissed notification into a new unread alert.
    func agentEventKey(sourceKey: String, signature: String, stableKey: String? = nil) -> String {
        if let previous = episodes.last(where: { $0.sourceKey == sourceKey }),
           previous.signature == signature { return previous.eventKey }
        let key = stableKey ?? UUID().uuidString
        episodes.removeAll { $0.sourceKey == sourceKey }
        episodes.append(AgentEpisode(sourceKey: sourceKey, signature: signature, eventKey: key))
        episodes = Array(episodes.suffix(Self.maximumEpisodes))
        persist()
        return key
    }

    /// An explicitly cleared report ends its episode, so a later identical
    /// request is a new event rather than the dismissed one.
    func endAgentEpisode(sourceKey: String) {
        guard episodes.contains(where: { $0.sourceKey == sourceKey }) else { return }
        episodes.removeAll { $0.sourceKey == sourceKey }
        persist()
    }

    @discardableResult
    func note(message: String, target: TerminalNotificationTarget, kind: TerminalNotificationRecord.Kind = .terminal,
              eventKey: String? = nil, isFailure: Bool = false, isPending: Bool = false,
              at date: Date = Date()) -> (record: TerminalNotificationRecord?, isNew: Bool) {
        guard let message = AgentConversationHistoryRecord.normalizedText(message, maximumBytes: 2_048),
              date.timeIntervalSince1970.isFinite else { return (nil, false) }
        let key = eventKey ?? UUID().uuidString
        guard !key.isEmpty, key.utf8.count <= 256 else { return (nil, false) }
        if let index = records.firstIndex(where: {
            $0.eventKey == key || eventKey == nil && $0.target.sourceKey == target.sourceKey && $0.kind == kind
                && $0.message == message && (0...2).contains(date.timeIntervalSince($0.createdAt))
        }) {
            if records[index].target != target || records[index].isPending != isPending {
                records[index].target = target
                records[index].isPending = isPending
                persist()
            }
            return (records[index], false)
        }
        guard !eventKeys.contains(key) else { return (nil, false) }
        let record = TerminalNotificationRecord(id: UUID(), eventKey: key, kind: kind, message: message,
            target: target, createdAt: date, isRead: false, isFailure: isFailure, isPending: isPending)
        guard record.isValid else { return (nil, false) }
        records.insert(record, at: 0)
        records = Array(records.prefix(Self.maximumRecords))
        eventKeys = Array((eventKeys + [key]).suffix(Self.maximumEventKeys))
        persist()
        return (record, true)
    }

    func markRead(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isRead else { return }
        records[index].isRead = true
        persist()
    }

    func markAllRead() {
        if isLoading { markedLoadedRecordsRead = true }
        records = records.map { var record = $0; record.isRead = true; return record }
        persist()
    }

    func resolvePending(sourceKey: String, exceptEventKey: String? = nil) {
        guard records.contains(where: {
            $0.target.sourceKey == sourceKey && $0.isPending && $0.eventKey != exceptEventKey
        }) else { return }
        records = records.map {
            var record = $0
            if record.target.sourceKey == sourceKey && record.eventKey != exceptEventKey { record.isPending = false }
            return record
        }
        persist()
    }

    func remove(id: UUID) {
        guard let record = record(id: id) else { return }
        if isLoading, removedWhileLoading.count < Self.maximumEventKeys { removedWhileLoading.insert(record.eventKey) }
        records.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        if isLoading { ignoredLoadedRecords = true }
        records.removeAll()
        persist()
    }

    func flush() async {
        if isLoading { await withCheckedContinuation { loadingWaiters.append($0) } }
        guard generation > 0 else { return }
        persistenceError = await withCheckedContinuation { continuation in
            persistence.flush { continuation.resume(returning: $0) }
        }
    }

    private func persist() {
        generation &+= 1
        guard !isLoading else { return }
        let current = generation
        persistence.enqueue(Snapshot(records: records, eventKeys: eventKeys, episodes: episodes)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.persistenceError = error
            }
        }
    }

    private func uniqueSuffix(_ keys: [String], maximum: Int) -> [String] {
        var seen = Set<String>()
        return Array(keys.reversed().filter { seen.insert($0).inserted }.prefix(maximum).reversed())
    }
}
