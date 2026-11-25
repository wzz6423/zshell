import Foundation

private enum BookmarkFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalCommandBookmarkTests {
    private static var checks = 0

    static func main() throws {
        var records = TerminalCommandRecords()
        try update(&records, blocks: [1, 2])
        let first = TerminalCommandBookmark(record: records.records[0])!
        let second = TerminalCommandBookmark(record: records.records[1])!
        var bookmarks = TerminalCommandBookmarks()
        try check(bookmarks.entries.isEmpty && !bookmarks.isClosed, "a new session starts without bookmarks")
        try check(bookmarks.toggle(first) && bookmarks.entries == [first], "adding a bookmark keeps the exact record identity and token")
        try check(bookmarks.toggle(second) && bookmarks.entries == [first, second], "adjacent blocks retain independent bookmarks")
        try check(bookmarks.toggle(first) && bookmarks.entries == [second], "toggling removes only the requested block")
        bookmarks.toggle(first)
        try update(&records, blocks: [1, 2], completed: true)
        bookmarks.reconcile(records.records)
        try check(bookmarks.entries == [second, first], "completion and reflow reports preserve stable bookmarks")

        var expired = records.records
        expired[0].outputLocation = nil
        bookmarks.reconcile(expired)
        try check(bookmarks.entries == [second], "cleared or invalidated output removes its bookmark")
        bookmarks.reconcile([])
        try check(bookmarks.entries.isEmpty, "evicted native records remove their bookmarks")

        bookmarks.toggle(first)
        try update(&records, blocks: [])
        try update(&records, blocks: [1])
        try check(records.records[0].id != first.id, "an evicted block ID gets a new record identity")
        bookmarks.reconcile(records.records)
        try check(bookmarks.entries.isEmpty, "a reused block ID never inherits an old bookmark")
        var replacement = TerminalCommandRecords()
        try update(&replacement, blocks: [1])
        bookmarks.toggle(TerminalCommandBookmark(record: records.records[0])!)
        bookmarks.reconcile(replacement.records)
        try check(bookmarks.entries.isEmpty, "a replacement surface cannot inherit another surface's token")
        var reusedIdentity = replacement.records[0]
        reusedIdentity = .init(
            id: first.id, command: reusedIdentity.command, workingDirectory: nil,
            startedAt: reusedIdentity.startedAt, outputLocation: reusedIdentity.outputLocation)
        bookmarks.toggle(first)
        bookmarks.reconcile([reusedIdentity])
        try check(bookmarks.entries.isEmpty, "matching record IDs do not override a different surface token")

        var missing = records.records[0]
        missing.outputLocation = nil
        try check(TerminalCommandBookmark(record: missing) == nil, "metadata without live output cannot create a bookmark")
        bookmarks.toggle(first)
        bookmarks.clear()
        try check(bookmarks.entries.isEmpty && !bookmarks.isClosed, "clear keeps the current session open for new bookmarks")
        bookmarks.toggle(first)
        bookmarks.close()
        try check(bookmarks.entries.isEmpty && bookmarks.isClosed, "closing releases every bookmark before teardown")
        try check(!bookmarks.toggle(second) && bookmarks.entries.isEmpty, "retained menus cannot add bookmarks after close")
        var other = TerminalCommandBookmarks()
        other.toggle(second)
        try check(other.entries == [second] && bookmarks.entries.isEmpty, "new sessions keep independent bookmark state")
        print("Command bookmarks: \(checks) checks passed")
    }

    private static func update(_ records: inout TerminalCommandRecords, blocks: [UInt64], completed: Bool = false) throws {
        let snapshots: [[String: Any]] = blocks.map { block in
            var snapshot: [String: Any] = [
                "blockID": block, "command": "printf 'block \(block)'",
                "startedAtMilliseconds": 1_700_000_000_000, "hasLocation": true,
            ]
            if completed {
                snapshot["finishedAtMilliseconds"] = 1_700_000_000_250
                snapshot["durationNanos"] = 250_000_000
                snapshot["exitCode"] = 0
            }
            return snapshot
        }
        _ = records.update(try JSONSerialization.data(withJSONObject: snapshots))
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BookmarkFailure.failed(message) }
        checks += 1
        print("PASS \(message)")
    }
}
