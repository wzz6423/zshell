import Darwin
import Foundation

nonisolated enum AgentConversationBinding {
    struct ProcessEvidence: Equatable {
        let parentPID: Int32
        let groupID: Int32
        let provider: AgentConversationIdentity.Provider?
        var isProviderLauncher = false
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
