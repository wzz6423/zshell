import AppKit
import Foundation
#if !HISTORY_STORE_PROBE
@testable import zshell
#endif

private enum CommandHistoryFailure: Error { case failed(String) }

@main
@MainActor
struct TerminalCommandHistoryTests {
    private static var checks = 0

    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try stores(in: root)
        #if HISTORY_RECORD_PROBE || !HISTORY_STORE_PROBE
        try records(in: root)
        #endif
        print("Command history: \(checks) checks passed")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CommandHistoryFailure.failed(message) }
        checks += 1
        print("PASS \(message)")
    }

    private static func wait(_ message: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try check(condition(), message)
    }

    private static func entry(_ index: Int, id: UUID = UUID(), command: String? = nil) -> TerminalCommandHistoryEntry {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        return .init(id: id, terminalID: UUID(), command: command ?? "printf '命令 \(index)'",
                     workingDirectory: "/tmp/café/项目", startedAt: date,
                     finishedAt: date.addingTimeInterval(0.125), durationNanos: 125_000_000, exitCode: 7)
    }

    private static func stores(in root: URL) throws {
        let url = root.appendingPathComponent("history/records.json")
        let store = TerminalCommandHistoryStore(url: url)
        try wait("history loads asynchronously") { !store.isLoading }
        let original = entry(1, command: "printf '你好 👩🏽‍💻'\nprintf 'second line'")
        store.note(original)
        store.note(original)
        try check(store.entries.count == 1, "identical lifecycle metadata does not duplicate a command")
        try check(store.search("你好 cafe").map(\.id) == [original.id], "search matches Unicode commands and accent-insensitive directories")
        try check(store.search("second 项目").count == 1, "search spans multiline command text and directory")
        store.flush()
        let reloaded = TerminalCommandHistoryStore(url: url)
        try wait("saved metadata reloads") { !reloaded.isLoading }
        try check(reloaded.entries == [original], "command, directory, dates, duration and exit status survive reload")
        try check((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize! < TerminalCommandHistoryStore.maximumBytes,
                  "serialized history stays under its byte cap")

        for index in 2...2_101 { store.note(entry(index)) }
        try check(store.entries.count == TerminalCommandHistoryStore.maximumRecords, "history evicts oldest records at the count limit")
        try check(store.entries.first?.command.contains("2101") == true
                  && store.entries.last?.command.contains("102") == true, "history retains the newest commands in descending order")
        store.flush()
        let bounded = TerminalCommandHistoryStore(url: url)
        try wait("bounded history reloads") { !bounded.isLoading }
        try check(bounded.entries == store.entries, "count eviction is durable")

        let race = TerminalCommandHistoryStore(url: url)
        let recent = entry(3_000, command: "new during load")
        race.note(recent)
        try wait("new commands merge after background loading") { !race.isLoading }
        try check(race.entries.first?.id == recent.id, "loading preserves new live records")
        race.delete(id: recent.id)
        race.flush()
        let deleted = TerminalCommandHistoryStore(url: url)
        try wait("deleted history reloads") { !deleted.isLoading }
        try check(!deleted.entries.contains { $0.id == recent.id }, "delete wins over pending writes")

        let clearing = TerminalCommandHistoryStore(url: url)
        clearing.clear()
        let afterClear = entry(4_000, command: "after clear")
        clearing.note(afterClear)
        try wait("clear during background load settles") { !clearing.isLoading }
        clearing.flush()
        let cleared = TerminalCommandHistoryStore(url: url)
        try wait("cleared history reloads") { !cleared.isLoading }
        try check(cleared.entries == [afterClear], "clear cannot resurrect loaded or queued records and keeps subsequent commands")

        let quitting = TerminalCommandHistoryStore(url: url)
        quitting.clear()
        quitting.note(original)
        quitting.flush()
        let quitReloaded = TerminalCommandHistoryStore(url: url)
        try wait("history reloads after immediate shutdown flush") { !quitReloaded.isLoading }
        try check(quitReloaded.entries == [original], "shutdown flush durably handles clear and new commands before async load completes")

        let bytesURL = root.appendingPathComponent("byte-history/records.json")
        let bytes = TerminalCommandHistoryStore(url: bytesURL)
        try wait("byte-limit fixture loads") { !bytes.isLoading }
        for index in 1...300 { bytes.note(entry(index, command: String(repeating: "字", count: 5_000))) }
        try check(bytes.entries.count < 300 && !bytes.entries.isEmpty, "history also evicts to its byte budget")
        bytes.flush()
        let encoded = try Data(contentsOf: bytesURL)
        try check(encoded.count <= TerminalCommandHistoryStore.maximumBytes, "large Unicode history stays within the file limit")
        let bytesReloaded = TerminalCommandHistoryStore(url: bytesURL)
        try wait("byte-bounded fixture reloads") { !bytesReloaded.isLoading }
        try check(bytesReloaded.entries == bytes.entries, "byte eviction preserves complete Unicode scalars")

        for command in ["", " \n\t ", "bad\u{1b}[31m", "bad\u{0}", String(repeating: "x", count: 16_385)] {
            let count = bytes.entries.count
            bytes.note(entry(5_000, command: command))
            try check(bytes.entries.count == count, "invalid or oversized command is rejected")
        }

        let brokenURL = root.appendingPathComponent("broken/records.json")
        try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try PersistentCLIConnection.writePrivate(Data("not json".utf8), to: brokenURL)
        let broken = TerminalCommandHistoryStore(url: brokenURL)
        try wait("corrupt history load settles") { !broken.isLoading }
        try check(broken.persistenceError != nil && broken.entries.isEmpty, "corrupt history exposes a load error")
        broken.clear()
        broken.flush()
        try check(broken.persistenceError == nil, "clear repairs an unreadable history with a bounded empty file")

        let target = root.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: target)
        let symlinkURL = root.appendingPathComponent("symlink/records.json")
        try FileManager.default.createDirectory(at: symlinkURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: target)
        let symlink = TerminalCommandHistoryStore(url: symlinkURL)
        try wait("symlink history load settles") { !symlink.isLoading }
        try check(symlink.persistenceError != nil, "history does not follow a linked records file")
        symlink.clear()
        symlink.flush()
        try check(try String(contentsOf: target, encoding: .utf8) == "unchanged", "atomic writes leave a symlink target untouched")
    }

    #if HISTORY_RECORD_PROBE || !HISTORY_STORE_PROBE
    private static func records(in root: URL) throws {
        let store = TerminalCommandHistoryStore(url: root.appendingPathComponent("command-records/records.json"))
        try wait("command-record integration loads") { !store.isLoading }
        let terminalID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_010_000)
        var record = TerminalCommandRecord(id: UUID(), command: "printf '命令 👩🏽‍💻'\nprintf 'next line'",
            workingDirectory: "/tmp/原目录", startedAt: startedAt, outputLocation: nil)
        store.observe([record], previous: [], terminalID: terminalID)
        try check(store.entries.first?.id == record.id && store.entries.first?.terminalID == terminalID,
                  "history uses the command block's stable ID and owning terminal ID")
        let running = record
        record.finishedAt = startedAt.addingTimeInterval(0.25)
        record.durationNanos = 250_000_000
        record.exitCode = 7
        store.observe([record], previous: [running], terminalID: terminalID)
        try check(store.entries == [TerminalCommandHistoryEntry(record: record, terminalID: terminalID)],
                  "completion updates metadata without duplicating a command")
        store.delete(id: record.id)
        store.observe([record], previous: [record], terminalID: terminalID)
        try check(store.entries.isEmpty, "later block reports cannot recreate a deleted history row")
        let next = TerminalCommandRecord(id: UUID(), command: record.command, workingDirectory: nil,
            startedAt: startedAt.addingTimeInterval(1), outputLocation: nil)
        store.observe([record, next], previous: [record], terminalID: terminalID)
        try check(store.entries.map(\.id) == [next.id] && store.entries.first?.workingDirectory == "",
                  "new commands survive deletion and unknown directories are not guessed")
        store.clear()
        var completed = next
        completed.finishedAt = next.startedAt.addingTimeInterval(1)
        completed.exitCode = 0
        store.observe([record, completed], previous: [record, next], terminalID: terminalID)
        try check(store.entries.isEmpty, "a running command finishing after clear cannot revive the list")
        let unknown = TerminalCommandRecord(id: UUID(), command: "", workingDirectory: nil,
                                           startedAt: startedAt.addingTimeInterval(2), outputLocation: nil)
        store.observe([unknown], previous: [], terminalID: terminalID)
        var known = unknown
        known.command = "echo now known"
        store.observe([known], previous: [unknown], terminalID: terminalID)
        try check(store.entries.map(\.id) == [known.id], "a block becomes eligible when its command text arrives")
        store.flush()
        let reloaded = TerminalCommandHistoryStore(url: root.appendingPathComponent("command-records/records.json"))
        try wait("integrated command metadata reloads") { !reloaded.isLoading }
        try check(reloaded.entries == store.entries, "clear and later new block observations remain durable")
    }
    #endif
}
