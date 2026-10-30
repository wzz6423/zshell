// Matching rules and label allocation adapted from Kaku's quickselect.rs.
// Copyright (c) 2024-Present Tw93
// Copyright (c) 2018-Present Wez Furlong
// Label algorithm: Copyright (c) 2019 Ferran Basora (tmux-thumbs).
// Complete MIT licenses and pinned sources: TerminalHints/NOTICE.md.

import Foundation

nonisolated struct TerminalHint: Equatable, Sendable {
    struct Fragment: Equatable, Sendable {
        let row: Int
        let columns: Range<Int>
    }
    let value: String
    let label: String
    let fragments: [Fragment]
}

nonisolated enum TerminalHintMatcher {
    static let alphabet = "asdfqwerzxcvjklmiuopghtybn"

    // Kaku PATTERNS, in their original precedence and capture-group form.
    static let patterns = [
        #"\[[^]]*\]\(([^)]+)\)"#,
        #"(?:https?://|git@|git://|ssh://|ftp://|file://)\S+"#,
        #"--- a/(\S+)"#,
        #"\+\+\+ b/(\S+)"#,
        #"sha256:([0-9a-f]{64})"#,
        #"(?:[.\w\-@~]+)?(?:/+[.\w\-@]+)+"#,
        #"#[0-9a-fA-F]{6}"#,
        #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        #"Qm[0-9a-zA-Z]{44}"#,
        #"[0-9a-f]{7,40}"#,
        #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#,
        #"[A-f0-9:]+:+[A-f0-9:]+[%\w\d]+"#,
        #"0x[0-9a-fA-F]+"#,
        #"[0-9]{4,}"#,
    ]

    private static let expressions = patterns.map { try! NSRegularExpression(pattern: $0) }
    // Bare hosts and filename diagnostics use Zshell's existing link router.
    private static let supplemental = try! NSRegularExpression(
        pattern: #"(?:\b(?:www\.[\w.-]+|localhost)(?::\d{1,5})?(?:[/?#][^\s<>"']*)?|(?:[.\w~@-]+/)*[\w.@-]+:\d+(?::\d+)?)"#
    )
    private static let locationSuffix = try! NSRegularExpression(pattern: #"^:\d+(?::\d+)?"#)

    static func labels(alphabet: String = alphabet, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let letters = alphabet.map { String($0).lowercased() }
        var primary = letters
        var secondary: [String] = []
        while primary.count + secondary.count < count {
            guard let prefix = primary.popLast() else { break }
            let prefixed = letters.prefix(count - primary.count - secondary.count).map { prefix + $0 }
            secondary.insert(contentsOf: prefixed, at: 0)
        }
        return Array(primary.prefix(max(0, count - secondary.count))) + secondary
    }

    static func matches(in snapshot: TerminalViewportSnapshot) -> [TerminalHint] {
        struct RowRange {
            let row: Int
            let range: NSRange
        }
        struct Candidate {
            let range: NSRange
            let value: String
        }
        var text = ""
        var rowRanges: [RowRange] = []
        for (index, row) in snapshot.rows.enumerated() {
            // Soft wraps form one logical line; hard newlines remain token
            // boundaries. Only the visible part of a logical line is read.
            rowRanges.append(RowRange(row: index, range: NSRange(location: text.utf16.count, length: row.text.utf16.count)))
            text += row.text
            if !row.wraps { text += "\n" }
        }
        let nsText = text as NSString
        let all = NSRange(location: 0, length: nsText.length)
        var candidates: [Candidate] = []
        var occupied = IndexSet()
        let ordered = Array(expressions.enumerated().prefix(6)) + [(patterns.count, supplemental)]
            + Array(expressions.enumerated().dropFirst(6))
        for (index, expression) in ordered {
            expression.enumerateMatches(in: text, range: all) { match, _, _ in
                guard let match else { return }
                var range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                guard range.location != NSNotFound, range.length > 0 else { return }
                if index == 5, NSMaxRange(range) < nsText.length {
                    let suffix = NSRange(location: NSMaxRange(range), length: nsText.length - NSMaxRange(range))
                    if let location = locationSuffix.firstMatch(in: text, options: .anchored, range: suffix) {
                        range.length += location.range.length
                    }
                }
                if index == 1 || index == expressions.count {
                    while range.length > 0, ").,;!?\"'>]}。，、；？！）".contains(nsText.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                        range.length -= 1
                    }
                }
                guard range.length > 0,
                      !nsText.substring(with: range).contains(where: \.isNewline) else { return }
                // Earlier patterns own overlaps (a URL is not also a path,
                // IP, hash and number). Keep duplicate values at distinct cells.
                let offsets = range.location..<NSMaxRange(range)
                guard !occupied.intersects(integersIn: offsets) else { return }
                occupied.insert(integersIn: offsets)
                candidates.append(Candidate(range: range, value: nsText.substring(with: range)))
            }
        }
        candidates.sort { $0.range.location < $1.range.location }
        let assigned = labels(count: candidates.count)
        return zip(candidates, assigned).compactMap { candidate, label in
            let fragments = rowRanges.compactMap { row -> TerminalHint.Fragment? in
                let overlap = NSIntersectionRange(row.range, candidate.range)
                guard overlap.length > 0,
                      let columns = snapshot.rows[row.row].columns(for: NSRange(location: overlap.location - row.range.location, length: overlap.length))
                else { return nil }
                return TerminalHint.Fragment(row: row.row, columns: columns)
            }
            return fragments.isEmpty ? nil : TerminalHint(value: candidate.value, label: label, fragments: fragments)
        }
    }
}
