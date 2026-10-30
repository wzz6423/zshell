import Darwin
import Foundation

@main
@MainActor
struct TerminalNotificationHistoryTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = root.appendingPathComponent("history/records.json")
        let target = TerminalNotificationTarget(terminalID: UUID(), projectID: UUID(), tabID: UUID(),
            paneID: UUID(), projectName: "Fixture", tabName: "Build")
        let store = TerminalNotificationHistoryStore(url: url)
        await store.flush()
        precondition(!store.isLoading && store.records.isEmpty && store.persistenceError == nil)
        let first = store.note(message: "Build needs input", target: target, kind: .agent,
                               eventKey: "first", isPending: true).record!
        let repeated = store.note(message: "Build needs input", target: target, kind: .agent,
                                  eventKey: "first", isPending: true)
        precondition(!repeated.isNew && repeated.record?.id == first.id && store.records.count == 1)
        store.markRead(id: first.id)
        precondition(store.filtered(.unread).isEmpty && store.filtered(.pending).count == 1)
        store.resolvePending(sourceKey: target.sourceKey)
        precondition(store.filtered(.pending).isEmpty)
        _ = store.note(message: "error is ordinary program text", target: target, eventKey: "text")
        precondition(store.filtered(.failed).isEmpty)
        _ = store.note(message: "Exited", target: target, kind: .command, eventKey: "failed", isFailure: true)
        precondition(store.filtered(.failed).count == 1)
        let episode = store.agentEventKey(sourceKey: target.sourceKey, signature: "blocked")
        precondition(episode == store.agentEventKey(sourceKey: target.sourceKey, signature: "blocked"))
        _ = store.agentEventKey(sourceKey: target.sourceKey, signature: "working")
        precondition(episode != store.agentEventKey(sourceKey: target.sourceKey, signature: "blocked"))
        let longText = String(repeating: "中", count: 2_000)
        let bounded = store.note(message: "\u{1b}\n" + longText, target: target, eventKey: "large").record!
        precondition(bounded.message.utf8.count <= 2_048 && !bounded.message.contains("\u{1b}"))
        print("PASS deduplication, independent filters, explicit failure, episode lifetime, UTF-8 bounds")

        for index in 0..<700 {
            _ = store.note(message: "Event \(index)", target: target, eventKey: "event:\(index)")
        }
        await store.flush()
        precondition(store.records.count == 200 && store.persistenceError == nil)
        let data = try Data(contentsOf: url)
        precondition(data.count <= TerminalNotificationHistoryStore.maximumBytes)
        let saved = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition((saved["eventKeys"] as! [String]).count == 512)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        let reloaded = TerminalNotificationHistoryStore(url: url)
        await reloaded.flush()
        precondition(reloaded.records == store.records)
        reloaded.clear()
        await reloaded.flush()
        precondition(reloaded.note(message: "replayed", target: target, eventKey: "event:699").record == nil)
        print("PASS 700-event burst: 200 records, 512 event keys, private bounded persistence, replay after clear")

        _ = reloaded.note(message: "Keep", target: target, eventKey: "keep")
        await reloaded.flush()
        let duringLoad = TerminalNotificationHistoryStore(url: url)
        _ = duringLoad.note(message: "Replayed", target: target, eventKey: "keep")
        duringLoad.markAllRead()
        await duringLoad.flush()
        precondition(duringLoad.records.count == 1 && duringLoad.records.allSatisfy(\.isRead))
        let clearing = TerminalNotificationHistoryStore(url: url)
        clearing.clear()
        _ = clearing.note(message: "Replayed", target: target, eventKey: "keep")
        await clearing.flush()
        precondition(clearing.records.isEmpty)
        let postClear = TerminalNotificationHistoryStore(url: url)
        postClear.clear()
        _ = postClear.note(message: "New", target: target, eventKey: "new")
        await postClear.flush()
        precondition(postClear.records.count == 1 && postClear.records[0].eventKey == "new")
        print("PASS mutations while loading: no resurrection, mark-all merging, new events survive clear")

        let malformedURL = root.appendingPathComponent("malformed/records.json")
        try PersistentCLIConnection.preparePrivateDirectory(malformedURL.deletingLastPathComponent())
        try PersistentCLIConnection.writePrivate(Data("{bad".utf8), to: malformedURL)
        let malformed = TerminalNotificationHistoryStore(url: malformedURL)
        await malformed.flush()
        precondition(malformed.records.isEmpty && malformed.persistenceError != nil)
        let oversizedURL = root.appendingPathComponent("oversized/records.json")
        try PersistentCLIConnection.preparePrivateDirectory(oversizedURL.deletingLastPathComponent())
        try PersistentCLIConnection.writePrivate(Data(repeating: 32,
            count: TerminalNotificationHistoryStore.maximumBytes + 1), to: oversizedURL)
        let oversized = TerminalNotificationHistoryStore(url: oversizedURL)
        await oversized.flush()
        precondition(oversized.records.isEmpty && oversized.persistenceError != nil)
        let symlinkURL = root.appendingPathComponent("symlink/records.json")
        try PersistentCLIConnection.preparePrivateDirectory(symlinkURL.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: url)
        let symlink = TerminalNotificationHistoryStore(url: symlinkURL)
        await symlink.flush()
        precondition(symlink.records.isEmpty && symlink.persistenceError != nil)
        print("PASS malformed, oversized, and symlinked history fail boundedly")

        let id = UUID()
        let command = TerminalCommandNotificationResult.parse(title: "zshell-command:\(id):2:7")!
        precondition(command.id == id && command.sequence == 2 && command.exitCode == 7)
        for title in ["failed", "zshell-command:bad:2:1", "zshell-command:\(id):0:1",
                      "zshell-command:\(id):1:256", "zshell-command:\(id):1:1:extra"] {
            precondition(TerminalCommandNotificationResult.parse(title: title) == nil)
        }
        print("PASS command failure uses typed exit metadata, never message keywords")
    }
}
