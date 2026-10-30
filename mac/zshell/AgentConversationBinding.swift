import Darwin
import Foundation

nonisolated enum AgentConversationBinding {
    struct ProcessEvidence: Equatable {
        let parentPID: Int32
        let groupID: Int32
        let provider: AgentConversationIdentity.Provider?
        var isProviderLauncher = false
        var isSharedService = false
    }

    /// A capability says which pane may be addressed, but a child agent can
    /// inherit it. Require the reporting root agent to own that pane's job.
    static func rootAgentPID(
        reporterPID: Int32,
        shellPID: Int32,
        foregroundPID: Int32,
        provider: AgentConversationIdentity.Provider,
        process: (Int32) -> ProcessEvidence?
    ) -> Int32? {
        guard reporterPID > 1, shellPID > 1, foregroundPID > 1 else { return nil }
        var visited = Set<Int32>()
        var current = reporterPID
        var agent: (pid: Int32, group: Int32)?
        for _ in 0..<64 {
            guard current > 1, visited.insert(current).inserted,
                  let evidence = process(current) else { return nil }
            guard !evidence.isSharedService else { return nil }
            if let detected = evidence.provider {
                guard detected == provider else { return nil }
                if let agent {
                    // The official npm launcher waits for its native Codex
                    // child in the same job. A nested CLI is a different root.
                    guard evidence.isProviderLauncher,
                          evidence.groupID == agent.group else { return nil }
                } else {
                    agent = (current, evidence.groupID)
                }
            }
            if current == shellPID {
                guard let agent,
                      agent.pid == foregroundPID || agent.group == foregroundPID
                else { return nil }
                return agent.pid
            }
            current = evidence.parentPID
        }
        return nil
    }

    // Adapted from Kero's sharedService at 580bdfa8f6a43d71d145958ab76c1bbb45c465f0
    // (MIT, Copyright (c) 2026 EGOIST). A daemon's first shell is not a pane owner.
    static func isSharedCodexService(arguments: [String]) -> Bool {
        arguments.contains("app-server") && arguments.contains("--managed-daemon")
    }

    static func sharedCodexServicePID(
        peerPID: Int32?, reporterPID: Int32,
        process: (Int32) -> ProcessEvidence?
    ) -> Int32? {
        guard let peerPID, peerPID > 1,
              reporterPID == peerPID || process(peerPID)?.parentPID == reporterPID else { return nil }
        var current = peerPID
        var visited = Set<Int32>()
        for _ in 0..<64 {
            guard current > 1, visited.insert(current).inserted,
                  let evidence = process(current) else { return nil }
            if evidence.isSharedService {
                return evidence.provider == .codex ? current : nil
            }
            // A CLI nested under a daemon cannot report for its enclosing thread.
            guard evidence.provider == nil else { return nil }
            current = evidence.parentPID
        }
        return nil
    }

    static func isCodexLauncher(executablePath: String?, arguments: [String]) -> Bool {
        guard let executablePath,
              ["node", "nodejs", "bun"].contains((executablePath as NSString).lastPathComponent),
              arguments.count >= 2 else { return false }
        let script = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path
        return script.hasSuffix("/@openai/codex/bin/codex.js")
    }

    static func reportingRootAgentPID(
        peerPID: Int32?,
        reporterPID: Int32,
        shellPID: Int32,
        foregroundPID: Int32,
        provider: AgentConversationIdentity.Provider,
        process: (Int32) -> ProcessEvidence?
    ) -> Int32? {
        guard let peerPID, peerPID > 1,
              reporterPID == peerPID || process(peerPID)?.parentPID == reporterPID
        else { return nil }
        // Start at the kernel-owned peer, including any inherited-capability
        // subagent between it and the claimed reporter.
        return rootAgentPID(
            reporterPID: peerPID, shellPID: shellPID, foregroundPID: foregroundPID,
            provider: provider, process: process
        )
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

/// Codex 0.165.0's session-id title item truncates UUIDs to 29 characters plus
/// "...". It is only a match against a complete authenticated hook identity.
nonisolated struct CodexTitleSessionEvidence: Equatable {
    let originalTitle: String
    let sessionPrefix: String
    let titleWithoutSessionID: String

    init?(title: String) {
        guard title.utf8.count <= 4_096,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let pattern = "(?<![0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-(?:[0-9A-Fa-f]{12}|[0-9A-Fa-f]{5}\\.\\.\\.)(?![0-9A-Fa-f.-])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
        guard matches.count == 1, let range = Range(matches[0].range, in: title) else { return nil }
        originalTitle = title
        let token = String(title[range]).lowercased()
        sessionPrefix = token.hasSuffix("...") ? String(token.dropLast(3)) : token
        var leading = String(title[..<range.lowerBound])
        var trailing = String(title[range.upperBound...])
        if leading.hasSuffix(" | ") { leading.removeLast(3) }
        else if trailing.hasPrefix(" | ") { trailing.removeFirst(3) }
        else if leading.hasSuffix(" ") { leading.removeLast() }
        titleWithoutSessionID = (leading + trailing).trimmingCharacters(in: .whitespaces)
    }

    func matches(sessionID: String) -> Bool {
        AgentConversationIdentity.Provider.codex.accepts(sessionID: sessionID)
            && sessionID.lowercased().hasPrefix(sessionPrefix)
    }
}
