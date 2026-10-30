import Foundation

nonisolated enum WorkspaceLogSearchIndex {
    struct Match: Sendable {
        let occurrence: Int
        let snippet: String
    }

    struct Result: Sendable {
        let matches: [Match]
        let total: Int
        let cancelled: Bool
    }

    /// Ghostty compares ASCII case-insensitively while leaving UTF-8 bytes
    /// intact. Keeping byte offsets also preserves composed and combining text.
    static func search(
        text: String, query: String, limit: Int, isCancelled: () -> Bool = { false }
    ) -> Result {
        let original = Array(text.utf8)
        let needle = Data(query.utf8.map(foldASCII))
        guard !needle.isEmpty, limit >= 0 else {
            return Result(matches: [], total: 0, cancelled: false)
        }
        let searchable = Data(original.map(foldASCII))
        var cursor = searchable.startIndex
        var total = 0
        var matches: [Match] = []
        while cursor < searchable.endIndex {
            if isCancelled() { return Result(matches: [], total: 0, cancelled: true) }
            guard let range = searchable.range(of: needle, in: cursor..<searchable.endIndex) else { break }
            if matches.count < limit {
                matches.append(Match(occurrence: total, snippet: snippet(original, range: range)))
            }
            total += 1
            cursor = range.upperBound
        }
        return Result(matches: matches, total: total, cancelled: false)
    }

    private static func foldASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func snippet(_ bytes: [UInt8], range: Range<Int>) -> String {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > 0, range.lowerBound - lower < 100, bytes[lower - 1] != 10 { lower -= 1 }
        while upper < bytes.count, upper - range.upperBound < 100, bytes[upper] != 10 { upper += 1 }
        while lower > 0, lower < bytes.count, bytes[lower] & 0xc0 == 0x80 { lower -= 1 }
        while upper < bytes.count, bytes[upper] & 0xc0 == 0x80 { upper += 1 }
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }
}
