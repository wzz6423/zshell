import Foundation

extension TerminalSession {
    func acceptRemoteAgentStatus(_ status: RemoteRelayStatus) {
        guard let connection = remoteConnection else { return }
        guard AppSettings.shared.aiEnabled else {
            if agentStatus != nil { clearAutomationAgentStatus() }
            return
        }
        if let value = status.conversation,
           let identity = AgentConversationIdentity.remote(value, hostID: connection.host.id,
                                                          project: connection.projectDirectory) {
            if agentResume != identity { recordAgentConversation(identity, processID: nil) }
        } else if status.state == .connected || status.state == .exited {
            if agentResume != nil { recordAgentConversation(nil, processID: nil) }
        }
        guard status.state == .connected || status.state == .exited, let report = status.agentStatus,
              report.records.count <= 64, let reportedPhase = ZshellAgentPhase(rawValue: report.phase),
              ZshellAgentReport.validText(report.message, maximum: 2_048)
        else { return }
        guard !report.records.isEmpty else {
            if agentStatus != nil { clearAutomationAgentStatus() }
            remoteAgentGeneration = report.generation
            return
        }
        let focused = TerminalManager.automationIsSessionFocused(id)
        let completed = reportedPhase == .done
        let alreadySeen = acknowledgedRemoteAgentGeneration == report.generation
        let phase: ZshellAgentPhase = completed && (focused || alreadySeen) ? .idle : reportedPhase
        let native = report.records.contains { $0.id == "native" || $0.id.hasPrefix("native/") }
        let provider = report.app.isEmpty ? agentResume?.provider.rawValue ?? "program" : report.app
        let kind = ZshellAgentKind(rawValue: provider) ?? .program
        let tasks = report.records.compactMap { record -> ZshellAgentTaskStatus? in
            guard !record.id.isEmpty, record.id != "native",
                  ZshellAgentReport.validText(record.id, maximum: 128),
                  ZshellAgentReport.validText(record.title, maximum: 256) else { return nil }
            let phase = record.state == "error" ? ZshellAgentPhase.blocked
                : ZshellAgentPhase(rawValue: record.state) ?? .unknown
            let attention: ZshellAgentAttention? = switch record.kind {
            case "permission": .approval
            case "question": .input
            case "auth": .login
            default: record.state == "error" ? .error : nil
            }
            return ZshellAgentTaskStatus(id: record.id, title: record.title.isEmpty ? record.id : record.title,
                phase: phase, progress: record.progress.flatMap { (0...100).contains($0) ? $0 : nil }, attention: attention)
        }
        updateAutomationAgentStatus(alias: agentResume?.alias ?? kind.displayName, kind: kind,
            phase: phase, authority: native ? .integration : .report,
            reason: report.message, processID: nil, unseen: phase == .done,
            progress: report.progress.flatMap { (0...100).contains($0) ? $0 : nil },
            attention: report.attention.flatMap(ZshellAgentAttention.init(rawValue:)), tasks: tasks)
        remoteAgentGeneration = report.generation
        if completed && focused && !alreadySeen { acknowledgeRemoteAgent() }
    }

    func acknowledgeRemoteAgent() {
        guard let connection = remoteConnection, let generation = remoteAgentGeneration,
              agentStatus?.phase == .done || agentStatus?.phase == .idle,
              acknowledgedRemoteAgentGeneration != generation else { return }
        acknowledgedRemoteAgentGeneration = generation
        connection.markAgentSeen()
        if let status = remoteStatus { acceptRemoteAgentStatus(status) }
    }
}
