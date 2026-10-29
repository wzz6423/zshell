//
//  AgentAutomation.swift
//  zshell
//

import AppKit
import Foundation

enum ZshellAgentKind: String, CaseIterable, Codable, Sendable {
    case codex
    case claude
    case gemini
    case grok
    case opencode
    case cursor = "cursor-agent"
    case aider
    case amp
    case pi
    case program

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok Build"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .aider: return "Aider"
        case .amp: return "Amp"
        case .pi: return "Pi"
        case .program: return String(localized: "Program")
        }
    }

    var executable: String { rawValue }

    static func recognize(processID: pid_t) -> Self? {
        recognize(
            executablePath: processExecutablePath(pid: processID),
            arguments: processArguments(pid: processID) ?? []
        )
    }

    static func recognize(
        executablePath: String?,
        arguments: [String] = []
    ) -> Self? {
        // argv[0] preserves the invoked symlink for versioned native installs
        // such as Claude and `exec -a` wrappers such as Cursor Agent.
        for value in [arguments.first, executablePath].compactMap({ $0 }) {
            if let kind = recognizeCommandName(value) { return kind }
        }

        guard let executablePath,
              isScriptInterpreter((executablePath as NSString).lastPathComponent)
        else { return nil }

        let tail = Array(arguments.dropFirst().prefix(8))
        if let moduleFlag = tail.firstIndex(of: "-m"),
           tail.indices.contains(moduleFlag + 1),
           let kind = recognizeScriptIdentity(tail[moduleFlag + 1]) {
            return kind
        }

        // For the supported wrappers the first non-option operand identifies
        // the script. Stop there rather than scanning prompts or user paths,
        // which would make ordinary interpreter jobs look like agents.
        for value in tail {
            if value.hasPrefix("-") || value == "run" { continue }
            return recognizeScriptIdentity(value)
        }
        return nil
    }

    private static func recognizeCommandName(_ value: String) -> Self? {
        var name = (value as NSString).lastPathComponent.lowercased()
        for suffix in [".exe", ".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        if name == "grok" || name == "xai-grok-pager" {
            return .grok
        }
        // Official installs resolve `~/.grok/bin/grok` to a versioned binary
        // such as `grok-1.0.0-macos-aarch64`; foreground PID inspection sees
        // that target even though argv[0] usually preserves the `grok` link.
        if name.hasPrefix("grok-"),
           name.contains("-macos-") || name.contains("-linux-") {
            return .grok
        }
        switch name {
        case "codex": return .codex
        case "claude": return .claude
        case "gemini": return .gemini
        case "opencode": return .opencode
        case "cursor-agent": return .cursor
        case "aider", "aider-chat": return .aider
        case "amp": return .amp
        case "pi": return .pi
        default: return nil
        }
    }

    private static func isScriptInterpreter(_ value: String) -> Bool {
        let name = value.lowercased()
        return name == "node" || name == "nodejs" || name == "bun"
            || name == "deno" || name == "python" || name.hasPrefix("python3")
            || name == "ruby" || name == "bash" || name == "sh" || name == "zsh"
    }

    private static func recognizeScriptIdentity(_ value: String) -> Self? {
        if let kind = recognizeCommandName(value) { return kind }
        let normalized = value.lowercased().replacingOccurrences(of: "\\", with: "/")
        if normalized.contains("/@openai/codex/") { return .codex }
        if normalized.contains("/@anthropic-ai/claude-code/") { return .claude }
        if normalized.contains("/gemini-cli/") { return .gemini }
        if normalized.contains("/grok-dev/") { return .grok }
        if normalized.contains("/opencode-ai/") { return .opencode }
        if normalized.contains("/cursor-agent/") { return .cursor }
        if normalized.contains("/aider-chat/") || normalized.contains("/aider_chat/") {
            return .aider
        }
        if normalized.contains("/sourcegraph/amp/") { return .amp }
        if normalized.contains("/pi-coding-agent/") { return .pi }
        return nil
    }
}

enum ZshellAgentPhase: String, Codable, CaseIterable, Sendable {
    case created
    case working
    case blocked
    case done
    case idle
    case unknown

    fileprivate var rollupPriority: Int {
        switch self {
        case .blocked: return 6
        case .done: return 5
        case .working: return 4
        case .unknown: return 3
        case .created: return 2
        case .idle: return 1
        }
    }
}

enum ZshellAgentStateAuthority: String, Codable, Sendable {
    /// A native agent hook or plugin reported a complete lifecycle event.
    case integration
    /// An authenticated program explicitly reported its own status.
    case report
    /// A bounded live viewport matched a known agent UI rule.
    case screen
    /// Zshell recognized the foreground executable.
    case process
    /// Zshell just launched or prompted the agent and is awaiting a lifecycle event.
    case command

    var displayName: String {
        switch self {
        case .integration: String(localized: "Native lifecycle")
        case .report: String(localized: "Program report")
        case .screen: String(localized: "Screen inference")
        case .process: String(localized: "Process detection")
        case .command: String(localized: "Submitted command")
        }
    }
}

struct ZshellAgentStatus: Equatable, Sendable {
    let alias: String
    let kind: ZshellAgentKind
    let phase: ZshellAgentPhase
    let authority: ZshellAgentStateAuthority
    let reason: String
    let updatedAt: Date
    let processID: pid_t?
    /// Completion remains unseen until the pane itself receives focus. Reads
    /// through the automation API deliberately do not mutate this bit.
    let unseen: Bool
    let progress: Int?
    let attention: ZshellAgentAttention?
    let tasks: [ZshellAgentTaskStatus]

    var detail: String {
        var lines = [String(localized: "Source: \(authority.displayName)")]
        if let attention { lines.append(attention.displayName) }
        if let progress { lines.append(String(localized: "Progress: \(progress)%")) }
        if authority == .report, !reason.isEmpty { lines.append(reason) }
        if !tasks.isEmpty { lines.append(String(localized: "Tasks: \(tasks.count)")) }
        for task in tasks.prefix(8) {
            let state = task.attention?.displayName ?? task.phase.statusDescription
            let progress = task.progress.map { " · \($0)%" } ?? ""
            lines.append("\(task.title) · \(state)\(progress)")
        }
        return lines.joined(separator: "\n")
    }
}

struct ZshellAgentRollup: Equatable {
    let phase: ZshellAgentPhase
    let count: Int
    let detail: String
    let progress: Int?
}

enum ZshellAutomationReadError: Error {
    case agentNotIdle
}

/// Mutable evidence kept beside a `TerminalSession`. It is separate from the
/// published status so unchanged polling never invalidates AppKit/SwiftUI view
/// trees.
@MainActor
final class ZshellAgentObservationState {
    var declaredKind: ZshellAgentKind?
    var alias: String?
    var lastForegroundPID: pid_t?
    var integrationPhase: ZshellAgentPhase?
    var integrationReason: String?
    var integrationOwner: ZshellAgentProcessIdentity?
    var codexConversationEvidence: (title: CodexTitleSessionEvidence, owner: ZshellAgentProcessIdentity)?
    var integrationAttention: ZshellAgentAttention?
    var integrationTasks: [ZshellAgentTaskStatus] = []
    var programReport: ZshellAgentProgramObservation?
    var lastProgramReportAt: Date?
    var screenEvidence: ZshellAgentScreenEvidence?
    var screenEvidenceSamples = 0
    var lastScreenCheck = Date.distantPast
    /// Native integrations publish semantic idle, not whether that idle ended
    /// a turn. Track active-turn evidence so launching an already-idle CLI in
    /// the background never looks like a newly finished task.
    var integrationTurnActive = false
    var isCollectingAlternateScreenHistory = false
    /// A Zshell-launched process is `created` until its first guarded prompt.
    /// This lifecycle fact does not require guessing how the CLI renders UI.
    var awaitingInitialPrompt = false
    /// Shell input is asynchronous. Keep a freshly declared launch working
    /// briefly so the monitor cannot mistake the still-foreground shell for
    /// an agent that already exited before it has consumed the command.
    var commandGraceDeadline: Date?
}

@MainActor
final class AgentAutomationMonitor {
    static let shared = AgentAutomationMonitor()

    /// Bound synchronous foreground-process probes on the common run loop so
    /// many parked tabs cannot monopolize one menu/input turn.
    private static let sessionsPerTick = 4

    private let sessions = NSHashTable<TerminalSession>.weakObjects()
    private var pendingSessionIDs: [UUID] = []
    private var timer: Timer?

    private init() {}

    func ownsTerminalProcess(_ pid: pid_t) -> Bool {
        sessions.allObjects.contains { session in
            session.shellPid.map { ZshellAgentProcessIdentity.isDescendant(pid, of: $0) } == true
        }
    }

    func register(_ session: TerminalSession) {
        AgentTurnReviewStore.shared.activeAgentCheck = { root in
            TerminalManager.automationManagers.contains { manager in
                manager.projects.contains { project in
                    project.sessions.contains { session in
                        guard !session.hasExited, let phase = session.agentStatus?.phase,
                              phase == .working || phase == .blocked || phase == .unknown else { return false }
                        let directory = URL(fileURLWithPath: session.currentDirectoryPath)
                            .resolvingSymlinksInPath().path
                        return directory == root || directory.hasPrefix(root + "/")
                    }
                }
            }
        }
        // Reconnecting a PTY reuses its ID while the detached renderer can
        // still be retained by the closing window.
        for previous in sessions.allObjects where previous.id == session.id {
            sessions.remove(previous)
        }
        sessions.add(session)
        guard !pendingSessionIDs.contains(session.id) else { return }
        pendingSessionIDs.append(session.id)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let liveSessions = sessions.allObjects.filter { !$0.hasExited }
        guard !liveSessions.isEmpty else {
            pendingSessionIDs.removeAll()
            timer?.invalidate()
            timer = nil
            return
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: liveSessions.map { ($0.id, $0) })
        var seenPendingSessionIDs = Set<UUID>()
        pendingSessionIDs.removeAll {
            sessionsByID[$0] == nil || !seenPendingSessionIDs.insert($0).inserted
        }
        for session in liveSessions where !seenPendingSessionIDs.contains(session.id) {
            pendingSessionIDs.append(session.id)
        }

        let focusedSessionID = TerminalManager.automationFocusedSessionID
        var refreshBatch: [TerminalSession] = []
        if let focusedSessionID, let session = sessionsByID[focusedSessionID] {
            refreshBatch.append(session)
            pendingSessionIDs.removeAll { $0 == focusedSessionID }
        }
        while refreshBatch.count < Self.sessionsPerTick, !pendingSessionIDs.isEmpty {
            let sessionID = pendingSessionIDs.removeFirst()
            if let session = sessionsByID[sessionID] {
                refreshBatch.append(session)
            }
        }

        for session in refreshBatch {
            session.refreshTerminalProfile()
            session.refreshAgentConversationHistory()
            session.refreshAutomationAgentState(isFocused: session.id == focusedSessionID)
        }
    }
}

extension TerminalSession {
    var isShellAvailableForAutomation: Bool {
        guard !hasExited, let shellPid, shellPid > 0 else { return false }
        return surface.foregroundPid == shellPid
            && ZshellAgentKind.recognize(processID: shellPid) == nil
            && commandLifecycle.phase != .executing
    }

    func isAutomationAgentRunning(kind: ZshellAgentKind) -> Bool {
        guard let foreground = surface.foregroundPid else { return false }
        return ZshellAgentKind.recognize(processID: foreground) == kind
    }

    /// Bounded viewport text for automation reads and diagnostics. Reading
    /// does not call `markAutomationAgentSeen()`.
    func automationVisibleText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        guard let text = surface.readVisibleText(
            maxLines: boundedLines, maxColumns: boundedColumns
        ) else { return "" }
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.prefix(boundedColumns)) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(boundedLines).joined(separator: "\n")
    }

    /// Recent host history for automation result reads. Unlike lifecycle
    /// detection, this deliberately asks the backend for bounded scrollback.
    func automationRecentText(maxLines: Int, maxColumns: Int) -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        return TerminalHistorySerializer.previewText(
            from: surface,
            maxLines: boundedLines,
            maxColumns: boundedColumns
        ) ?? automationVisibleText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
    }

    /// Collects older transcript pages from an idle full-screen agent when its
    /// alternate buffer has no host scrollback. Every page overlaps the prior
    /// page, and the same wheel interface is driven back to the live bottom
    /// before the read completes. Unsupported applications simply return the
    /// passive recent snapshot after the first wheel event changes nothing.
    func automationReadText(
        maxLines: Int,
        maxColumns: Int,
        requireIdleAgentForHistory: Bool
    ) async throws -> String {
        let boundedLines = min(max(maxLines, 1), 500)
        let boundedColumns = min(max(maxColumns, 1), 2_000)
        let recent = automationRecentText(
            maxLines: boundedLines,
            maxColumns: boundedColumns
        )
        let recentLines = Self.automationLines(recent)
        guard recentLines.count < boundedLines,
              !TerminalHistorySerializer.hasPrimaryScrollback(surface),
              terminalIsAtLiveBottom,
              let status = agentStatus,
              isAutomationAgentRunning(kind: status.kind),
              !agentObservation.isCollectingAlternateScreenHistory
        else { return recent }

        guard status.phase == .idle || status.phase == .done else {
            if requireIdleAgentForHistory { throw ZshellAutomationReadError.agentNotIdle }
            return recent
        }

        var latestPage = Self.automationLines(
            automationVisibleText(
                maxLines: boundedLines,
                maxColumns: boundedColumns
            )
        )
        guard !latestPage.isEmpty else { return recent }

        var collected = latestPage
        let pageStep = min(max(latestPage.count - 4, 4), 50)
        var pagesMoved = 0
        agentObservation.isCollectingAlternateScreenHistory = true
        defer { agentObservation.isCollectingAlternateScreenHistory = false }

        while collected.count < boundedLines, pagesMoved < 32 {
            guard surface.sendApplicationScroll(lines: pageStep) else { break }
            pagesMoved += 1
            try? await Task.sleep(for: .milliseconds(90))

            let olderPage = Self.automationLines(
                automationVisibleText(
                    maxLines: boundedLines,
                    maxColumns: boundedColumns
                )
            )
            guard !olderPage.isEmpty, olderPage != latestPage else { break }
            let merged = Self.prependingAutomationPage(
                olderPage,
                previousPage: latestPage,
                collected: collected
            )
            guard merged != collected else { break }
            collected = merged
            latestPage = olderPage
        }

        if pagesMoved > 0 {
            // Each downward batch is at least as large as the upward page step;
            // two extra batches cover applications that clamp one wheel burst.
            for _ in 0..<(pagesMoved + 2) {
                guard surface.sendApplicationScroll(lines: -50) else { break }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        return collected.suffix(boundedLines).joined(separator: "\n")
    }

    private static func automationLines(_ text: String) -> [String] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func prependingAutomationPage(
        _ olderPage: [String],
        previousPage: [String],
        collected: [String]
    ) -> [String] {
        var olderContent = olderPage

        // Full-screen agents often pin an input/status footer while their
        // transcript scrolls. Drop one copy before looking for page overlap.
        let maximumFooter = min(8, min(olderPage.count, previousPage.count))
        var sharedFooter = 0
        if maximumFooter > 0 {
            for count in stride(from: maximumFooter, through: 1, by: -1)
            where Array(olderPage.suffix(count)) == Array(previousPage.suffix(count)) {
                sharedFooter = count
                break
            }
        }
        if sharedFooter > 0 { olderContent.removeLast(sharedFooter) }
        guard !olderContent.isEmpty else { return collected }

        let maximumOverlap = min(olderContent.count, collected.count)
        var overlap = 0
        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1)
            where Array(olderContent.suffix(count)) == Array(collected.prefix(count)) {
                overlap = count
                break
            }
        }
        return Array(olderContent.dropLast(overlap)) + collected
    }

    func declareAutomationAgent(alias: String, kind: ZshellAgentKind) {
        clearNativeAgentObservation()
        agentObservation.programReport = nil
        agentObservation.alias = alias
        agentObservation.declaredKind = kind
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = false
        agentObservation.awaitingInitialPrompt = true
        agentObservation.commandGraceDeadline = Date().addingTimeInterval(5)
        updateAutomationAgentStatus(
            alias: alias,
            kind: kind,
            phase: .working,
            authority: .command,
            reason: "Zshell launched \(kind.displayName)",
            processID: nil,
            unseen: false
        )
    }

    func markAutomationAgentPrompted() {
        guard let status = agentStatus else { return }
        clearNativeAgentObservation()
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationTurnActive = true
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
        updateAutomationAgentStatus(
            alias: status.alias,
            kind: status.kind,
            phase: .working,
            authority: .command,
            reason: "Prompt submitted",
            processID: surface.foregroundPid,
            unseen: false
        )
    }

    func reportAutomationAgent(
        phase: ZshellAgentPhase,
        reason: String?,
        provider: ZshellAgentKind,
        peerProcessID: pid_t,
        attention: ZshellAgentAttention? = nil,
        task: ZshellAgentTaskStatus? = nil,
        endsSession: Bool = false,
        daemonSessionID: String? = nil
    ) -> Bool {
        guard !hasExited else { return false }
        var owner: ZshellAgentProcessIdentity?
        if let daemonSessionID {
            guard provider == .codex,
                  CodexDaemonBinding.lifecycleTarget(
                    sessionID: daemonSessionID, peerPID: peerProcessID, reporterPID: peerProcessID
                  )?.session === self else { return false }
            owner = foregroundCodexConversationOwner
        } else {
            guard let shell = shellPid,
                  ZshellAgentProcessIdentity.isDescendant(peerProcessID, of: shell) else { return false }
            var candidate = peerProcessID
            var nearestProvider: ZshellAgentProcessIdentity?
            for _ in 0..<64 {
                if Self.conversationProcessEvidence(candidate)?.isSharedService == true { return false }
                if ZshellAgentKind.recognize(processID: candidate) == provider {
                    owner = ZshellAgentProcessIdentity(pid: candidate)
                    if nearestProvider == nil { nearestProvider = owner }
                }
                if candidate == shell { break }
                guard let parent = ZshellAgentProcessIdentity.parent(of: candidate), parent > 1 else { break }
                candidate = parent
            }
            // Nested invocations can update their own task, not the parent turn.
            guard task != nil || nearestProvider == owner else { return false }
        }
        guard let owner else { return false }
        if let foreground = surface.foregroundPid,
           let foregroundKind = ZshellAgentKind.recognize(processID: foreground),
           foregroundKind != provider { return false }
        if agentObservation.integrationOwner != owner {
            agentObservation.integrationTasks.removeAll()
            agentObservation.integrationTurnActive = false
        }
        let alias = agentObservation.declaredKind == provider
            ? agentObservation.alias ?? provider.rawValue : provider.rawValue
        agentObservation.alias = alias
        agentObservation.declaredKind = provider
        agentObservation.integrationOwner = owner
        agentObservation.commandGraceDeadline = nil
        if task == nil, reason == "\(provider.displayName): SessionStart" {
            agentObservation.integrationTasks.removeAll()
            agentObservation.integrationTurnActive = false
        }
        if endsSession {
            clearAutomationAgentStatus()
            return true
        }
        if let task {
            var tasks = agentObservation.integrationTasks
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
            else if tasks.count < ZshellAgentReport.maximumTasks { tasks.append(task) }
            else if let index = tasks.firstIndex(where: { $0.phase == .done || $0.phase == .idle }) {
                tasks.remove(at: index)
                tasks.append(task)
            }
            agentObservation.integrationTasks = tasks
            if phase == .working { agentObservation.integrationTurnActive = true }
            if agentObservation.integrationPhase == nil { agentObservation.integrationPhase = .working }
        } else {
            agentObservation.integrationPhase = phase
            agentObservation.integrationAttention = attention
        }
        agentObservation.integrationReason = reason
        if phase == .working || phase == .blocked {
            agentObservation.integrationTurnActive = true
            agentObservation.awaitingInitialPrompt = false
        }
        presentNativeAgentStatus(isFocused: TerminalManager.automationIsSessionFocused(id))
        return true
    }

    func reportAutomationProgram(
        _ report: ZshellAgentReport, ownerPID: pid_t, peerProcessID: pid_t
    ) -> Bool {
        guard !hasExited, let shell = shellPid,
              ZshellAgentProcessIdentity.isDescendant(peerProcessID, of: ownerPID),
              ZshellAgentProcessIdentity.isDescendant(ownerPID, of: shell),
              let owner = ZshellAgentProcessIdentity(pid: ownerPID)
        else { return false }
        let finished = report.activityPhase == .done
            && agentObservation.programReport?.report.activityPhase != .done
        if agentStatus?.authority == .report,
           agentObservation.programReport?.report.phase != report.phase {
            agentStatus = nil
        }
        agentObservation.programReport = ZshellAgentProgramObservation(
            report: report, owner: owner, updatedAt: Date()
        )
        agentObservation.lastProgramReportAt = Date()
        refreshAutomationAgentState(isFocused: TerminalManager.automationIsSessionFocused(id))
        if finished { ZshellAutomationEventHub.shared.agentReportFinished(in: self) }
        return true
    }

    func clearAutomationProgram(peerProcessID: pid_t) -> Bool {
        guard let shell = shellPid,
              ZshellAgentProcessIdentity.isDescendant(peerProcessID, of: shell) else { return false }
        if let report = agentObservation.programReport,
           !ZshellAgentProcessIdentity.isDescendant(peerProcessID, of: report.owner.pid) {
            return false
        }
        agentObservation.programReport = nil
        if agentStatus?.authority == .report { agentStatus = nil }
        refreshAutomationAgentState(isFocused: TerminalManager.automationIsSessionFocused(id))
        return true
    }

    func markAutomationAgentSeen() {
        if remoteConnection != nil { acknowledgeRemoteAgent(); return }
        guard let status = agentStatus, status.phase == .done || status.unseen else { return }
        if status.authority == .report {
            guard agentObservation.programReport?.isCurrent(at: Date()) == true else {
                agentObservation.programReport = nil
                agentStatus = nil
                return
            }
        } else {
            guard agentObservation.integrationOwner?.isAlive == true
                || isAutomationAgentRunning(kind: status.kind) else {
                clearAutomationAgentStatus()
                return
            }
            agentObservation.integrationPhase = .idle
            agentObservation.integrationReason = "Completion viewed"
            agentObservation.integrationTurnActive = false
        }
        updateAutomationAgentStatus(
            alias: status.alias, kind: status.kind, phase: .idle,
            authority: status.authority, reason: status.reason,
            processID: status.processID, unseen: false,
            progress: status.progress, attention: nil, tasks: status.tasks
        )
    }

    private func presentNativeAgentStatus(isFocused: Bool) {
        guard let owner = agentObservation.integrationOwner,
              let kind = agentObservation.declaredKind,
              let reported = agentObservation.integrationPhase else { return }
        let tasks = agentObservation.integrationTasks
        let blockedChild = tasks.first(where: { $0.phase == .blocked })
        let childrenWorking = tasks.contains(where: { $0.phase == .working })
        var phase = blockedChild != nil ? ZshellAgentPhase.blocked
            : childrenWorking && (reported == .idle || reported == .done) ? .working : reported
        let initialIdle = agentObservation.awaitingInitialPrompt && phase == .idle
        let completedTurn = agentObservation.integrationTurnActive
            || agentStatus?.phase == .working || agentStatus?.phase == .blocked
        if initialIdle { phase = .created }
        else if phase == .idle || phase == .done {
            // Preserve a previously acknowledged completion when focus changes.
            let unseenCompletion = agentStatus?.authority == .integration && agentStatus?.unseen == true
            phase = !isFocused && (completedTurn || unseenCompletion) ? .done : .idle
            agentObservation.integrationTurnActive = false
        }
        updateAutomationAgentStatus(
            alias: agentObservation.alias ?? kind.rawValue, kind: kind, phase: phase,
            authority: .integration,
            reason: agentObservation.integrationReason ?? "Reported by native agent integration",
            processID: owner.pid, unseen: phase == .done,
            attention: blockedChild?.attention ?? agentObservation.integrationAttention,
            tasks: tasks
        )
    }

    fileprivate func refreshAutomationAgentState(isFocused: Bool) {
        guard !hasExited else { clearAutomationAgentStatus(); return }
        if isFocused { markAutomationAgentSeen() }
        let now = Date()
        if let owner = agentObservation.integrationOwner, !owner.isAlive {
            clearNativeAgentObservation()
            if agentStatus?.authority == .integration { agentStatus = nil }
        }
        if let report = agentObservation.programReport, !report.isCurrent(at: now) {
            agentObservation.programReport = nil
            if agentStatus?.authority == .report { agentStatus = nil }
        }
        if agentObservation.integrationOwner != nil, agentObservation.integrationPhase != nil {
            presentNativeAgentStatus(isFocused: isFocused)
            return
        }
        if let observation = agentObservation.programReport {
            let report = observation.report
            let seen = agentStatus?.authority == .report && agentStatus?.phase == .idle
                && agentStatus?.processID == observation.owner.pid
            let phase = (report.activityPhase == .done && (isFocused || seen))
                ? ZshellAgentPhase.idle : report.activityPhase
            updateAutomationAgentStatus(
                alias: report.name, kind: .program, phase: phase, authority: .report,
                reason: report.reason, processID: observation.owner.pid,
                unseen: phase == .done, progress: report.progress,
                attention: report.activityAttention, tasks: report.tasks
            )
            return
        }
        let foreground = surface.foregroundPid
        let kind = foreground.flatMap(ZshellAgentKind.recognize(processID:))
        if foreground != agentObservation.lastForegroundPID {
            agentObservation.lastForegroundPID = foreground
            agentObservation.screenEvidence = nil
            agentObservation.screenEvidenceSamples = 0
        }
        guard let kind else {
            if let deadline = agentObservation.commandGraceDeadline, now < deadline { return }
            clearAutomationAgentStatus()
            return
        }
        if let previous = agentStatus, previous.kind != kind || previous.processID != foreground {
            clearNativeAgentObservation()
            agentObservation.alias = nil
            agentObservation.awaitingInitialPrompt = false
        }
        agentObservation.commandGraceDeadline = nil
        let alias = agentObservation.alias ?? kind.rawValue
        agentObservation.alias = alias
        agentObservation.declaredKind = kind

        if now.timeIntervalSince(agentObservation.lastScreenCheck) >= 1.5 {
            agentObservation.lastScreenCheck = now
            let evidence = terminalIsAtLiveBottom && !agentObservation.isCollectingAlternateScreenHistory
                ? ZshellAgentScreenEvidence.detect(
                    kind: kind, text: automationVisibleText(maxLines: 32, maxColumns: 240)
                  ) : nil
            agentObservation.screenEvidenceSamples = evidence == agentObservation.screenEvidence
                ? agentObservation.screenEvidenceSamples + 1 : 1
            agentObservation.screenEvidence = evidence
        }
        if let evidence = agentObservation.screenEvidence,
           agentObservation.screenEvidenceSamples >= 2 {
            updateAutomationAgentStatus(
                alias: alias, kind: kind, phase: evidence.phase, authority: .screen,
                reason: evidence.reason, processID: foreground, unseen: false,
                attention: evidence.attention
            )
            return
        }
        if agentObservation.awaitingInitialPrompt {
            updateAutomationAgentStatus(
                alias: alias, kind: kind, phase: .created, authority: .process,
                reason: "Agent process created; no task has been submitted",
                processID: foreground, unseen: false
            )
        } else if let current = agentStatus, current.authority == .command, current.phase == .working {
            updateAutomationAgentStatus(
                alias: alias, kind: kind, phase: .working, authority: .command,
                reason: current.reason, processID: foreground, unseen: false
            )
        } else {
            updateAutomationAgentStatus(
                alias: alias, kind: kind, phase: .idle, authority: .process,
                reason: "Directly launched \(kind.displayName) detected", processID: foreground, unseen: false
            )
        }
    }

    private func clearNativeAgentObservation() {
        agentObservation.integrationPhase = nil
        agentObservation.integrationReason = nil
        agentObservation.integrationOwner = nil
        agentObservation.integrationAttention = nil
        agentObservation.integrationTasks.removeAll()
        agentObservation.integrationTurnActive = false
    }

    func clearAutomationAgentStatus() {
        AgentTurnReviewStore.shared.abort(sessionID: id)
        agentStatus = nil
        agentObservation.alias = nil
        agentObservation.declaredKind = nil
        clearNativeAgentObservation()
        agentObservation.programReport = nil
        agentObservation.screenEvidence = nil
        agentObservation.screenEvidenceSamples = 0
        agentObservation.awaitingInitialPrompt = false
        agentObservation.commandGraceDeadline = nil
    }

    func updateAutomationAgentStatus(
        alias: String,
        kind: ZshellAgentKind,
        phase: ZshellAgentPhase,
        authority: ZshellAgentStateAuthority,
        reason: String,
        processID: pid_t?,
        unseen: Bool,
        progress: Int? = nil,
        attention: ZshellAgentAttention? = nil,
        tasks: [ZshellAgentTaskStatus] = []
    ) {
        if let current = agentStatus,
           current.alias == alias,
           current.kind == kind,
           current.phase == phase,
           current.authority == authority,
           current.reason == reason,
           current.processID == processID,
           current.unseen == unseen,
           current.progress == progress,
           current.attention == attention,
           current.tasks == tasks {
            return
        }

        let previousPhase = agentStatus?.phase
        agentStatus = ZshellAgentStatus(
            alias: alias,
            kind: kind,
            phase: phase,
            authority: authority,
            reason: reason,
            updatedAt: Date(),
            processID: processID,
            unseen: unseen,
            progress: progress,
            attention: attention,
            tasks: tasks
        )

        guard authority != .screen, phase != previousPhase,
              phase == .blocked || phase == .done,
              !TerminalManager.automationIsSessionFocused(id)
        else { return }
        TerminalNotificationService.shared.post(
            message: phase == .blocked
                ? String(localized: "\(alias) needs attention")
                : String(localized: "\(alias) finished"),
            sessionID: id
        )
    }
}

extension PaneTab {
    var agentRollup: ZshellAgentRollup? {
        Self.rollup(sessions.compactMap(\.agentStatus))
    }

    fileprivate static func rollup(_ statuses: [ZshellAgentStatus]) -> ZshellAgentRollup? {
        // Idle and unknown remain useful to automation clients, but neither is
        // actionable enough to occupy persistent pane, tab, or project chrome.
        let visibleStatuses = statuses.filter {
            $0.phase != .idle && $0.phase != .unknown
        }
        guard let phase = visibleStatuses.map(\.phase).max(by: {
            $0.rollupPriority < $1.rollupPriority
        }) else { return nil }
        return ZshellAgentRollup(
            phase: phase,
            count: visibleStatuses.filter { $0.phase == phase }.count,
            detail: visibleStatuses.prefix(8).map { "\($0.alias)\n\($0.detail)" }.joined(separator: "\n\n"),
            progress: visibleStatuses.count == 1 ? visibleStatuses.first?.progress : nil
        )
    }
}

extension TerminalSession {
    var agentRollup: ZshellAgentRollup? {
        PaneTab.rollup(agentStatus.map { [$0] } ?? [])
    }
}

extension Project {
    var agentRollup: ZshellAgentRollup? {
        PaneTab.rollup(sessions.compactMap(\.agentStatus))
    }
}
