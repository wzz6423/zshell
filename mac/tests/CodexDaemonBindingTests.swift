import Darwin
import Foundation

@main
struct CodexDaemonBindingTests {
    static var count = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        let passed = try condition()
        precondition(passed, message)
        count += 1
        print("PASS \(message)")
    }

    static func main() throws {
        try processBinding()
        try titleEvidence()
        try configuration()
        print("Codex daemon binding: \(count) checks passed")
    }

    static func processBinding() throws {
        let shell: Int32 = 10, daemon: Int32 = 20, hook: Int32 = 30
        var processes: [Int32: AgentConversationBinding.ProcessEvidence] = [
            shell: .init(parentPID: 1, groupID: shell, provider: nil),
            daemon: .init(parentPID: shell, groupID: 20, provider: .codex, isSharedService: true),
            hook: .init(parentPID: daemon, groupID: 30, provider: nil),
        ]
        try check(AgentConversationBinding.isSharedCodexService(arguments: ["codex", "app-server", "--managed-daemon"]),
                  "Kero shared-service boundary recognizes the official daemon")
        try check(!AgentConversationBinding.isSharedCodexService(arguments: ["codex", "app-server"]),
                  "embedded app-server retains ordinary process ownership")
        try check(AgentConversationBinding.rootAgentPID(reporterPID: hook, shellPID: shell,
            foregroundPID: daemon, provider: .codex, process: { processes[$0] }) == nil,
                  "a managed daemon never inherits its first shell's pane ownership")
        try check(AgentConversationBinding.sharedCodexServicePID(peerPID: hook, reporterPID: hook,
            process: { processes[$0] }) == daemon, "kernel-owned hook peer identifies its daemon")
        try check(AgentConversationBinding.sharedCodexServicePID(peerPID: hook, reporterPID: shell,
            process: { processes[$0] }) == nil, "an arbitrary claimed reporter cannot borrow a peer")
        processes[40] = .init(parentPID: daemon, groupID: 40, provider: .codex)
        processes[hook] = .init(parentPID: 40, groupID: 40, provider: nil)
        try check(AgentConversationBinding.sharedCodexServicePID(peerPID: hook, reporterPID: hook,
            process: { processes[$0] }) == nil, "a nested Codex cannot report for its ancestor daemon")
        processes[40] = .init(parentPID: shell, groupID: 40, provider: .codex)
        try check(AgentConversationBinding.rootAgentPID(reporterPID: hook, shellPID: shell,
            foregroundPID: 40, provider: .codex, process: { processes[$0] }) == 40,
                  "ordinary foreground Codex preserves process binding")
        processes[50] = .init(parentPID: 40, groupID: 50, provider: .codex)
        processes[hook] = .init(parentPID: 50, groupID: 50, provider: nil)
        try check(AgentConversationBinding.rootAgentPID(reporterPID: hook, shellPID: shell,
            foregroundPID: 40, provider: .codex, process: { processes[$0] }) == nil,
                  "nested CLI rejection remains in the ordinary path")
    }

    static func titleEvidence() throws {
        let first = "550e8400-e29b-41d4-a716-446655440000"
        let second = "550e8400-e29b-41d4-b716-446655440000"
        let title = "Fix login | project | \(first.prefix(29))..."
        let evidence = CodexTitleSessionEvidence(title: title)!
        try check(evidence.matches(sessionID: first), "official truncated title matches a complete hook ID")
        try check(!evidence.matches(sessionID: second), "same cwd and title text cannot match another TUI")
        try check(evidence.titleWithoutSessionID == "Fix login | project", "managed UUID leaves user title parts intact")
        try check(CodexTitleSessionEvidence(title: first)?.matches(sessionID: first) == true,
                  "a future full UUID title is accepted")
        try check(CodexTitleSessionEvidence(title: title + " | " + second) == nil,
                  "multiple session tokens are rejected as ambiguous")
        try check(CodexTitleSessionEvidence(title: "\u{1b}" + title) == nil, "control characters never become title identity")
        try check(CodexTitleSessionEvidence(title: String(first.prefix(20)) + "...") == nil,
                  "short session prefixes are not trusted")
        let collision = String(first.prefix(29)) + "9999999"
        try check(evidence.matches(sessionID: collision), "prefix collision is surfaced for unique full-identity selection")
        let root = FileManager.default.temporaryDirectory.path
        let nested = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "session_id": first,
            "cwd": root, "parent_session_id": second])
        try check(AgentConversationSessionEvent.sessionStart(provider: .codex, payload: nested, environment: [:],
            reporterPID: getpid(), currentDirectory: root) == nil, "nested SessionStart cannot become a root identity")
    }

    static func configuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zshell-title-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let original = Data("# Keep this comment\nmodel = 'fixture'\n[tui]\nterminal_title = ['activity', 'project-name'] # Keep this too\n".utf8)
        try original.write(to: config)
        let installed = try CodexTitleConfiguration.plan(root: root, previous: nil, installing: true)!
        try check(installed.state?.installedItems == ["activity", "project-name", "session-id"],
                  "official config API appends one title item after user selections")
        try check(try Data(contentsOf: config) == original, "preflight never mutates the real provider configuration")
        try check(String(decoding: installed.updated!, as: UTF8.self).contains("# Keep this comment"),
                  "official TOML edit preserves unrelated configuration comments")
        try installed.updated!.write(to: config)
        let repeated = try CodexTitleConfiguration.plan(root: root, previous: installed.state, installing: true)!
        try check(repeated.updated == installed.updated && repeated.state == installed.state,
                  "reconciliation is idempotent and retains the initial backup")
        let restored = try CodexTitleConfiguration.plan(root: root, previous: installed.state, installing: false)!
        try check(restored.updated == original, "uninstall restores untouched user configuration byte for byte")
        var edited = installed.updated!
        edited.append(Data("\n[analytics]\nenabled = false\n".utf8))
        try edited.write(to: config)
        let merged = try CodexTitleConfiguration.plan(root: root, previous: installed.state, installing: false)!
        try check(String(decoding: merged.updated!, as: UTF8.self).contains("[analytics]") && merged.updated != original,
                  "uninstall keeps subsequent user edits outside the title item")
        try check(!String(decoding: merged.updated!, as: UTF8.self).contains("session-id"),
                  "uninstall removes only Zshell's session title item after an unrelated edit")
        try Data("[tui]\nterminal_title = ['session-id', 'project-name']\n".utf8).write(to: config)
        let owned = try CodexTitleConfiguration.plan(root: root, previous: nil, installing: true)!
        try check(owned.state == nil && owned.updated == owned.original,
                  "an existing user session-id selection stays user owned")
    }
}
