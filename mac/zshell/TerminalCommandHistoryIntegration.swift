import Foundation

extension TerminalCommandHistoryEntry {
    init(record: TerminalCommandRecord, terminalID: UUID) {
        self.init(id: record.id, terminalID: terminalID, command: record.command,
                  workingDirectory: record.workingDirectory ?? "", startedAt: record.startedAt,
                  finishedAt: record.finishedAt, durationNanos: record.durationNanos, exitCode: record.exitCode)
    }
}

extension TerminalCommandHistoryStore {
    func observe(_ records: [TerminalCommandRecord], previous: [TerminalCommandRecord], terminalID: UUID) {
        let previousEntries = Dictionary(previous.map {
            ($0.id, TerminalCommandHistoryEntry(record: $0, terminalID: terminalID))
        }, uniquingKeysWith: { _, newest in newest })
        for record in records {
            let entry = TerminalCommandHistoryEntry(record: record, terminalID: terminalID)
            if let prior = previousEntries[entry.id] {
                guard prior != entry else { continue }
                if prior.isValid {
                    // Completion and reflow reports must not recreate a deleted history row.
                    update(entry)
                } else { note(entry) }
            } else { note(entry) }
        }
    }
}
