import Combine
import Foundation
import Synchronization

nonisolated struct AgentConversationHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var identity: AgentConversationIdentity
    var projectID: UUID
    var projectName: String
    var title: String?
    var terminalID: UUID
    let startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var isArchived: Bool

    var displayTitle: String { title ?? identity.alias ?? identity.provider.displayName }

    static func normalizedText(_ text: String?, maximumBytes: Int = 256) -> String? {
        guard let text else { return nil }
        let value = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(value)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= maximumBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    init(
        id: UUID = UUID(), identity: AgentConversationIdentity, projectID: UUID,
        projectName: String, title: String?, terminalID: UUID, at: Date
    ) {
        self.id = id
        self.identity = identity
        self.projectID = projectID
        self.projectName = Self.normalizedText(projectName) ?? identity.provider.displayName
        self.title = Self.normalizedText(title)
        self.terminalID = terminalID
        startedAt = at
        updatedAt = at
        endedAt = nil
        isArchived = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, identity, projectID, projectName, title, terminalID, startedAt, updatedAt, endedAt, isArchived
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        identity = try values.decode(AgentConversationIdentity.self, forKey: .identity)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        projectName = Self.normalizedText(try values.decode(String.self, forKey: .projectName))
            ?? identity.provider.displayName
        title = Self.normalizedText(try values.decodeIfPresent(String.self, forKey: .title))
        terminalID = try values.decode(UUID.self, forKey: .terminalID)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        guard startedAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt >= startedAt,
              endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= startedAt }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt, in: values, debugDescription: "Invalid conversation history dates"
            )
        }
    }

    func matches(_ identity: AgentConversationIdentity) -> Bool {
        self.identity.matchesConversation(identity)
    }

    var searchText: String {
        [displayTitle, identity.provider.displayName, identity.provider.rawValue,
         identity.alias ?? "", identity.sessionID, identity.workingDirectory,
         identity.configDirectory ?? "", projectName].joined(separator: " ")
    }
}

enum AgentConversationHistoryPaths {
    static var directoryURL: URL {
        #if DEBUG
        let name = "zshell-dev"
        #else
        let name = "zshell"
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(name)/conversation-history", isDirectory: true)
    }

    static var recordsURL: URL { directoryURL.appendingPathComponent("records.json") }
    static var connectionsURL: URL { directoryURL.appendingPathComponent("connections", isDirectory: true) }

    static func prepare(_ directory: URL = directoryURL) throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try PersistentCLIConnection.preparePrivateDirectory(directory)
    }
}

@MainActor
final class AgentConversationHistoryStore: ObservableObject {
    static let shared = AgentConversationHistoryStore()
    static let maximumRecords = 200
    static let recentLimit = 20
    private nonisolated static let maximumBytes = 8 * 1024 * 1024

    enum Filter: Int, CaseIterable {
        case recent, all, archived
    }

    private nonisolated struct SavedRecords: Codable {
        let version: Int
        let records: [AgentConversationHistoryRecord]

        init(records: [AgentConversationHistoryRecord]) {
            version = 1
            self.records = records
        }

        private enum CodingKeys: String, CodingKey { case version, records }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            var list = try values.nestedUnkeyedContainer(forKey: .records)
            var records: [AgentConversationHistoryRecord] = []
            while !list.isAtEnd {
                let decoder = try list.superDecoder()
                if let record = try? AgentConversationHistoryRecord(from: decoder) { records.append(record) }
            }
            self.records = records
        }
    }

    private nonisolated final class Persistence: Sendable {
        private struct PendingWrite: Sendable {
            let records: [AgentConversationHistoryRecord]
            let completion: @Sendable (String?) -> Void
        }

        private struct State: Sendable {
            var pending: PendingWrite?
            var scheduled = false
            var error: String?
        }

        private let url: URL
        private let queue = DispatchQueue(label: "sh.zshell.conversation-history.persistence", qos: .utility)
        private let state = Mutex(State())

        init(url: URL) { self.url = url }

        func enqueue(_ records: [AgentConversationHistoryRecord], completion: @escaping @Sendable (String?) -> Void) {
            let needsWorker = state.withLock { state in
                state.pending = PendingWrite(records: records, completion: completion)
                guard !state.scheduled else { return false }
                state.scheduled = true
                return true
            }
            guard needsWorker else { return }
            queue.async { [self] in
                while let next = state.withLock({ state -> PendingWrite? in
                    let next = state.pending
                    state.pending = nil
                    if next == nil { state.scheduled = false }
                    return next
                }) {
                    do { try write(next.records); next.completion(nil) }
                    catch { next.completion(String(describing: error)) }
                }
            }
        }

        // Explicit mutations follow pending observations and acknowledge only
        // a durable write, so an older snapshot cannot undo archive or delete.
        func save(_ records: [AgentConversationHistoryRecord]) throws {
            try queue.sync { try write(records) }
        }

        func flush() -> String? { queue.sync { state.withLock { $0.error } } }

        private func write(_ records: [AgentConversationHistoryRecord]) throws {
            do {
                try PersistentCLIConnection.verifyPrivateDirectory(url.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(SavedRecords(records: records))
                guard data.count <= maximumBytes else { throw CLIError.message("Conversation history exceeds its size limit.") }
                try PersistentCLIConnection.writePrivate(data, to: url, durable: true)
                state.withLock { $0.error = nil }
            } catch {
                state.withLock { $0.error = String(describing: error) }
                throw error
            }
        }
    }

    @Published private(set) var records: [AgentConversationHistoryRecord] = []
    @Published private(set) var persistenceError: String?
    private let url: URL
    private let persistence: Persistence
    private var persistenceGeneration: UInt64 = 0

    init(url: URL? = nil) {
        let url = url ?? AgentConversationHistoryPaths.recordsURL
        self.url = url
        persistence = Persistence(url: url)
        do {
            try AgentConversationHistoryPaths.prepare(url.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let saved = try JSONDecoder().decode(
                SavedRecords.self, from: PersistentCLIConnection.readPrivate(url, maximumBytes: Self.maximumBytes)
            )
            guard saved.version == 1 else { throw CLIError.message("Unsupported conversation history version.") }
            var unique: [AgentConversationHistoryRecord] = []
            for record in saved.records.sorted(by: Self.ranksBefore)
            where !unique.contains(where: { $0.id == record.id || $0.matches(record.identity) }) {
                unique.append(record)
                if unique.count == Self.maximumRecords { break }
            }
            records = unique
        } catch {
            persistenceError = String(describing: error)
            NSLog("zshell: could not load conversation history: \(error)")
        }
    }

    func record(id: UUID, projectID: UUID? = nil) -> AgentConversationHistoryRecord? {
        records.first { $0.id == id && (projectID == nil || $0.projectID == projectID) }
    }

    func search(
        _ query: String = "", filter: Filter = .recent, projectID: UUID? = nil
    ) -> [AgentConversationHistoryRecord] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        let matches = records.filter { record in
            guard projectID == nil || record.projectID == projectID else { return false }
            switch filter {
            case .recent: guard !record.isArchived else { return false }
            case .archived: guard record.isArchived else { return false }
            case .all: break
            }
            let candidate = record.searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { candidate.contains($0) }
        }.sorted(by: Self.ranksBefore)
        return filter == .recent ? Array(matches.prefix(Self.recentLimit)) : matches
    }

    @discardableResult
    func note(
        _ identity: AgentConversationIdentity, projectID: UUID, projectName: String,
        title: String?, terminalID: UUID, at: Date = Date()
    ) -> UUID {
        var next = records
        let id: UUID
        if let index = next.firstIndex(where: { $0.matches(identity) }) {
            id = next[index].id
            next[index].identity = identity
            next[index].projectID = projectID
            next[index].projectName = AgentConversationHistoryRecord.normalizedText(projectName)
                ?? next[index].projectName
            next[index].title = AgentConversationHistoryRecord.normalizedText(title) ?? next[index].title
            next[index].terminalID = terminalID
            next[index].updatedAt = max(at, next[index].updatedAt)
            next[index].endedAt = nil
        } else {
            let record = AgentConversationHistoryRecord(
                identity: identity, projectID: projectID, projectName: projectName,
                title: title, terminalID: terminalID, at: at
            )
            id = record.id
            next.append(record)
        }
        next.sort(by: Self.ranksBefore)
        next = Array(next.prefix(Self.maximumRecords))
        records = next
        persistObservedRecords()
        return id
    }

    func ended(id: UUID, terminalID: UUID, title: String? = nil, at: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.terminalID == terminalID }),
              records[index].endedAt == nil else { return }
        records[index].endedAt = max(at, records[index].startedAt)
        records[index].updatedAt = max(at, records[index].updatedAt)
        records[index].title = AgentConversationHistoryRecord.normalizedText(title) ?? records[index].title
        records.sort(by: Self.ranksBefore)
        persistObservedRecords()
    }

    func setArchived(_ archived: Bool, id: UUID, projectID: UUID? = nil) throws {
        guard let index = records.firstIndex(where: { $0.id == id && (projectID == nil || $0.projectID == projectID) }) else {
            throw AgentConversationHistoryError.notFound
        }
        var next = records
        next[index].isArchived = archived
        try save(next)
        records = next
    }

    func delete(id: UUID, projectID: UUID? = nil) throws {
        guard record(id: id, projectID: projectID) != nil else { throw AgentConversationHistoryError.notFound }
        let next = records.filter { $0.id != id }
        try save(next)
        records = next
    }

    private static func ranksBefore(_ lhs: AgentConversationHistoryRecord, _ rhs: AgentConversationHistoryRecord) -> Bool {
        lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id.uuidString < rhs.id.uuidString
    }

    private func persistObservedRecords() {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        persistence.enqueue(records) { [weak self] error in
            if let error { NSLog("zshell: could not save conversation history: \(error)") }
            Task { @MainActor [weak self] in
                guard let self, self.persistenceGeneration == generation else { return }
                self.persistenceError = error
            }
        }
    }

    func flush() {
        guard persistenceGeneration > 0 else { return }
        persistenceError = persistence.flush()
    }

    private func save(_ records: [AgentConversationHistoryRecord]) throws {
        persistenceGeneration &+= 1
        do {
            try persistence.save(records)
            persistenceError = nil
        } catch {
            persistenceError = String(describing: error)
            throw error
        }
    }
}

enum AgentConversationHistoryError: Error, LocalizedError {
    case notFound, disabled, unavailableDirectory, unavailableConfiguration, unavailableSessionFile, differentProject, noWindow

    var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "This conversation is no longer in the selected project’s history.")
        case .disabled: String(localized: "Enable AI integration before resuming a conversation.")
        case .unavailableDirectory: String(localized: "The conversation’s working directory is no longer available.")
        case .unavailableConfiguration: String(localized: "The conversation’s configuration directory is no longer available.")
        case .unavailableSessionFile: String(localized: "The Pi session file is missing or does not match this conversation.")
        case .differentProject: String(localized: "This conversation is already open in another project or window.")
        case .noWindow: String(localized: "Open a Zshell window before resuming a conversation.")
        }
    }
}
