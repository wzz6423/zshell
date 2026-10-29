import Combine
import Foundation
import Synchronization

nonisolated struct TerminalCommandHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let terminalID: UUID
    let command: String
    let workingDirectory: String
    let startedAt: Date
    let finishedAt: Date?
    let durationNanos: UInt64?
    let exitCode: Int?

    var isValid: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && command.utf8.count <= 16_384 && workingDirectory.utf8.count <= 4_096
            && command.unicodeScalars.allSatisfy {
                !Self.isControlCode($0) || $0 == "\n" || $0 == "\t"
            }
            && workingDirectory.unicodeScalars.allSatisfy { !Self.isControlCode($0) }
            && startedAt.timeIntervalSince1970.isFinite
            && (finishedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= startedAt } ?? true)
            && (exitCode.map { (0...255).contains($0) } ?? true)
    }

    // JSON escaping can expand one byte to six; cap memory before encoding
    // without serializing a full history on the terminal's main-actor path.
    var storageCost: Int { 512 + 6 * (command.utf8.count + workingDirectory.utf8.count) }

    private static func isControlCode(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
    }
}

@MainActor
final class TerminalCommandHistoryStore: ObservableObject {
    static let shared = TerminalCommandHistoryStore()
    nonisolated static let maximumRecords = 2_000
    nonisolated static let maximumBytes = 8 * 1_024 * 1_024

    @Published private(set) var entries: [TerminalCommandHistoryEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var persistenceError: String?
    private let persistence: Persistence
    private var generation: UInt64 = 0
    private var discardLoadedEntries = false
    private var removedDuringLoad = Set<UUID>()
    private var storageBytes = 128

    init(url: URL? = nil) {
        #if DEBUG
        let name = "zshell-dev"
        #else
        let name = "zshell"
        #endif
        let url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(name)/command-history/records.json")
        persistence = Persistence(url: url)
        persistence.load { [weak self] loaded, error in
            Task { @MainActor [weak self] in
                self?.finishLoading(loaded, error: error)
            }
        }
    }

    private func finishLoading(_ loaded: [TerminalCommandHistoryEntry], error: String?) {
        guard isLoading else { return }
        if !discardLoadedEntries {
            let currentIDs = Set(entries.map(\.id))
            entries = Self.bounded(entries + loaded.filter {
                !currentIDs.contains($0.id) && !removedDuringLoad.contains($0.id)
            })
            storageBytes = 128 + entries.reduce(0) { $0 + $1.storageCost }
        }
        removedDuringLoad.removeAll()
        isLoading = false
        persistenceError = error
        persistence.releaseLoadedEntries()
        if generation > 0 { persist() }
    }

    func search(_ query: String) -> [TerminalCommandHistoryEntry] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let candidate = (entry.command + "\n" + entry.workingDirectory)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy { candidate.contains($0) }
        }
    }

    func note(_ entry: TerminalCommandHistoryEntry) {
        guard entry.isValid else { return }
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) {
            guard next[index] != entry else { return }
            storageBytes -= next.remove(at: index).storageCost
        }
        let index = next.firstIndex { Self.ranksBefore(entry, $0) } ?? next.endIndex
        next.insert(entry, at: index)
        storageBytes += entry.storageCost
        while next.count > Self.maximumRecords || storageBytes > Self.maximumBytes {
            storageBytes -= next.removeLast().storageCost
        }
        entries = next
        changed()
    }

    func update(_ entry: TerminalCommandHistoryEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        note(entry)
    }

    func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        storageBytes -= entries.remove(at: index).storageCost
        if isLoading { removedDuringLoad.insert(id) }
        changed()
    }

    func clear() {
        entries.removeAll()
        storageBytes = 128
        discardLoadedEntries = true
        changed()
    }

    // Only shutdown waits for the worker. Observing commands, loading, clearing
    // and deleting remain asynchronous, with writes ordered on the same queue.
    func flush() {
        if isLoading {
            let loaded = persistence.waitForLoad()
            finishLoading(loaded.entries, error: loaded.error)
        }
        persistenceError = persistence.flush()
    }

    private func changed() {
        generation &+= 1
        if !isLoading { persist() }
    }

    private func persist() {
        let current = generation
        persistence.enqueue(entries) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.persistenceError = error
            }
        }
    }

    private nonisolated static func bounded(_ entries: [TerminalCommandHistoryEntry]) -> [TerminalCommandHistoryEntry] {
        var bytes = 128
        var ids = Set<UUID>()
        return entries.sorted(by: ranksBefore).filter { entry in
            guard ids.count < maximumRecords, entry.isValid,
                  !ids.contains(entry.id), bytes + entry.storageCost <= maximumBytes else { return false }
            ids.insert(entry.id)
            bytes += entry.storageCost
            return true
        }
    }

    private nonisolated static func ranksBefore(_ left: TerminalCommandHistoryEntry, _ right: TerminalCommandHistoryEntry) -> Bool {
        left.startedAt == right.startedAt ? left.id.uuidString > right.id.uuidString : left.startedAt > right.startedAt
    }

    private nonisolated struct SavedEntries: Codable {
        let version: Int
        let entries: [TerminalCommandHistoryEntry]
    }

    private nonisolated final class Persistence: Sendable {
        struct LoadedEntries: Sendable {
            let entries: [TerminalCommandHistoryEntry]
            let error: String?
        }
        private struct PendingWrite: Sendable {
            let entries: [TerminalCommandHistoryEntry]
            let completion: @Sendable (String?) -> Void
        }
        private struct State: Sendable {
            var pending: PendingWrite?
            var scheduled = false
            var error: String?
            var loaded = LoadedEntries(entries: [], error: nil)
        }
        private let url: URL
        private let queue = DispatchQueue(label: "sh.zshell.command-history.persistence", qos: .utility)
        private let state = Mutex(State())

        init(url: URL) { self.url = url }

        func load(completion: @escaping @Sendable ([TerminalCommandHistoryEntry], String?) -> Void) {
            queue.async { [self] in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent().deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try PersistentCLIConnection.preparePrivateDirectory(url.deletingLastPathComponent())
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        didLoad([], error: nil, completion: completion)
                        return
                    }
                    let saved = try JSONDecoder().decode(SavedEntries.self, from:
                        PersistentCLIConnection.readPrivate(url, maximumBytes: maximumBytes))
                    guard saved.version == 1 else { throw CLIError.message("Unsupported command history version.") }
                    didLoad(TerminalCommandHistoryStore.bounded(saved.entries), error: nil, completion: completion)
                } catch { didLoad([], error: String(describing: error), completion: completion) }
            }
        }

        private func didLoad(_ entries: [TerminalCommandHistoryEntry], error: String?,
                             completion: @Sendable ([TerminalCommandHistoryEntry], String?) -> Void) {
            state.withLock {
                $0.loaded = LoadedEntries(entries: entries, error: error)
                $0.error = error
            }
            completion(entries, error)
        }

        func waitForLoad() -> LoadedEntries { queue.sync { state.withLock { $0.loaded } } }

        func releaseLoadedEntries() { state.withLock { $0.loaded = LoadedEntries(entries: [], error: nil) } }

        func enqueue(_ entries: [TerminalCommandHistoryEntry], completion: @escaping @Sendable (String?) -> Void) {
            let schedule = state.withLock { state in
                state.pending = PendingWrite(entries: entries, completion: completion)
                guard !state.scheduled else { return false }
                state.scheduled = true
                return true
            }
            guard schedule else { return }
            queue.async { [self] in
                while let next = state.withLock({ state -> PendingWrite? in
                    let pending = state.pending
                    state.pending = nil
                    if pending == nil { state.scheduled = false }
                    return pending
                }) {
                    var error: String?
                    do {
                        try PersistentCLIConnection.verifyPrivateDirectory(url.deletingLastPathComponent())
                        let data = try JSONEncoder().encode(SavedEntries(version: 1, entries: next.entries))
                        guard data.count <= maximumBytes else { throw CLIError.message("Command history exceeds its size limit.") }
                        try PersistentCLIConnection.writePrivate(data, to: url, durable: true)
                    } catch let failure { error = String(describing: failure) }
                    state.withLock { $0.error = error }
                    next.completion(error)
                }
            }
        }

        func flush() -> String? { queue.sync { state.withLock { $0.error } } }
    }
}
