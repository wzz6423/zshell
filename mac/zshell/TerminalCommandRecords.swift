import Foundation

private struct TerminalCommandSnapshot: Decodable {
    let blockID: UInt64
    let command: String
    let workingDirectory: String?
    let startedAtMilliseconds: Int64
    let finishedAtMilliseconds: Int64?
    let durationNanos: UInt64?
    let exitCode: Int?
    let hasLocation: Bool
}

struct TerminalCommandRecords {
    let surfaceID = UUID()
    private var identities: [UInt64: UUID] = [:]
    private(set) var records: [TerminalCommandRecord] = []

    mutating func update(_ data: Data) -> Bool {
        guard data.count <= 64 * 1_024 * 1_024,
              let snapshots = try? JSONDecoder().decode([TerminalCommandSnapshot].self, from: data),
              snapshots.count <= 2_000 else { return false }
        let blockIDs = Set(snapshots.map(\.blockID))
        guard blockIDs.count == snapshots.count else { return false }
        identities = identities.filter { blockIDs.contains($0.key) }
        let updated = snapshots.map { snapshot in
            let id = identities[snapshot.blockID] ?? UUID()
            identities[snapshot.blockID] = id
            return TerminalCommandRecord(
                id: id, command: snapshot.command, workingDirectory: snapshot.workingDirectory,
                startedAt: Date(timeIntervalSince1970: Double(snapshot.startedAtMilliseconds) / 1_000),
                finishedAt: snapshot.finishedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                durationNanos: snapshot.durationNanos, exitCode: snapshot.exitCode,
                outputLocation: snapshot.hasLocation ? .init(surfaceID: surfaceID, blockID: snapshot.blockID) : nil
            )
        }
        guard records != updated else { return false }
        records = updated
        return true
    }

    func owns(_ location: TerminalCommandOutputLocation) -> Bool { location.surfaceID == surfaceID }
}

extension TerminalCommandTextPart {
    var nativeValue: UInt8 {
        switch self { case .command: 0; case .output: 1; case .wholeBlock: 2 }
    }
}
