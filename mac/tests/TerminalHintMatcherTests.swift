import Foundation
#if ZSHELL_HINT_APP
@testable import zshell
#endif

@main
struct TerminalHintMatcherTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: message, code: 1) }
            checks += 1
        }
        for (alphabet, count, expected) in [
            ("abcd", 3, ["a", "b", "c"]),
            ("abcd", 6, ["a", "b", "c", "da", "db", "dc"]),
            ("abcd", 8, ["a", "b", "ca", "cb", "da", "db", "dc", "dd"]),
            ("ab", 5, ["aa", "ab", "ba", "bb"]),
        ] {
            try check(TerminalHintMatcher.labels(alphabet: alphabet, count: count) == expected, "Kaku label vector \(alphabet)/\(count)")
        }
        for count in 0...800 {
            let labels = TerminalHintMatcher.labels(count: count)
            try check(labels.count == min(count, 676), "alphabet capacity \(count)")
            try check(Set(labels).count == labels.count, "labels remain unique \(count)")
            try check(!labels.contains(where: { label in labels.contains { $0 != label && $0.hasPrefix(label) } }), "labels remain prefix-free \(count)")
        }
        func row(_ text: String, wraps: Bool = false, start: Int = 0) -> TerminalViewportRow {
            TerminalViewportRow(cells: text.enumerated().map { .init(text: String($0.element), column: start + $0.offset, width: 1) }, wraps: wraps)
        }
        func snapshot(_ rows: [TerminalViewportRow]) -> TerminalViewportSnapshot {
            .init(rows: rows, columns: 120, origin: .init(x: 10, y: 8), cellSize: .init(width: 8, height: 16))
        }
        let values = ["https://example.com/a", "/tmp/source.swift:12:3", "main.swift:42:7", "192.168.1.2", "2001:db8::1", "deadbee", "localhost:3000", "www.example.com/x"]
        let hints = TerminalHintMatcher.matches(in: snapshot(values.map { row($0) }))
        try check(hints.map(\.value) == values, "paths, locations, URLs, IPs and hashes stay whole")
        try check(hints.map { $0.fragments[0].row } == Array(values.indices), "hard newlines remain token boundaries")
        let duplicate = TerminalHintMatcher.matches(in: snapshot([row("deadbee deadbee")]))
        try check(duplicate.count == 2 && duplicate[0].label != duplicate[1].label, "duplicate values retain separate labels")
        try check(duplicate[1].fragments[0].columns == 8..<15, "duplicate position is exact")
        let wrapped = TerminalHintMatcher.matches(in: snapshot([row("https://example.com/", wraps: true), row("path")]))
        try check(wrapped.map(\.value) == ["https://example.com/path"], "soft-wrapped URL is one hint")
        try check(wrapped[0].fragments.count == 2 && wrapped[0].fragments[1].columns == 0..<4, "soft-wrap fragments align with cells")
        var cells = [TerminalViewportCell(text: "中", column: 0, width: 2), .init(text: "😀", column: 2, width: 2),
                     .init(text: "e\u{301}", column: 4, width: 1), .init(text: " ", column: 5, width: 1)]
        cells += "deadbee".enumerated().map { .init(text: String($0.element), column: 6 + $0.offset, width: 1) }
        let unicode = snapshot([TerminalViewportRow(cells: cells, wraps: false)])
        let unicodeHint = TerminalHintMatcher.matches(in: unicode)[0]
        try check(unicodeHint.fragments[0].columns == 6..<13, "wide and combining text use emulator columns")
        try check(unicode.rect(row: 0, columns: 6..<13) == CGRect(x: 58, y: 8, width: 56, height: 16), "host-point geometry is exact")
        let markdown = TerminalHintMatcher.matches(in: snapshot([row("[site](https://example.com/a)"), row("--- a/Sources/main.swift"), row("sha256:" + String(repeating: "a", count: 64))]))
        try check(markdown.map(\.value) == ["https://example.com/a", "Sources/main.swift", String(repeating: "a", count: 64)], "Kaku capture groups keep their values")
        let punctuation = TerminalHintMatcher.matches(in: snapshot([row("(https://example.com/a).")]))
        try check(punctuation.map(\.value) == ["https://example.com/a"], "sentence punctuation is not copied")
        let many = snapshot((0..<100).map { row("https://example.com/\($0) " + String(repeating: "x ", count: 45)) })
        let started = Date()
        for _ in 0..<10 { _ = TerminalHintMatcher.matches(in: many) }
        print("PASS \(checks) terminal hint matcher checks; 10 bounded scans in \(Date().timeIntervalSince(started))s")
    }
}
