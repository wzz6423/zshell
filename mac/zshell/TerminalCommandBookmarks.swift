import Foundation

struct TerminalCommandBookmark: Equatable, Identifiable {
    let id: UUID
    let location: TerminalCommandOutputLocation

    init?(record: TerminalCommandRecord) {
        guard let location = record.outputLocation else { return nil }
        id = record.id
        self.location = location
    }
}

struct TerminalCommandBookmarks {
    private(set) var entries: [TerminalCommandBookmark] = []
    private(set) var isClosed = false

    func contains(_ bookmark: TerminalCommandBookmark) -> Bool { entries.contains(bookmark) }

    @discardableResult
    mutating func toggle(_ bookmark: TerminalCommandBookmark) -> Bool {
        guard !isClosed else { return false }
        if contains(bookmark) {
            remove(bookmark)
        } else {
            entries.append(bookmark)
        }
        return true
    }

    mutating func remove(_ bookmark: TerminalCommandBookmark) { entries.removeAll { $0 == bookmark } }
    mutating func clear() { entries.removeAll() }

    mutating func reconcile(_ records: [TerminalCommandRecord]) {
        guard !entries.isEmpty else { return }
        let locations = Dictionary(
            records.compactMap { record in
                record.outputLocation.map { (record.id, $0) }
            }, uniquingKeysWith: { _, newest in newest })
        // A native block ID can be reused by a replacement surface. Keep the
        // record identity and surface token together instead of retargeting it.
        entries.removeAll { locations[$0.id] != $0.location }
    }

    mutating func close() {
        clear()
        isClosed = true
    }
}
