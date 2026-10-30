import AppKit
import Foundation
import UserNotifications

nonisolated struct TerminalNotificationAuthorization: Sendable {
    enum Status: Sendable { case allowed, undetermined, denied }
    let status: Status
    var needsSoundUpgrade = false
}

@MainActor
protocol TerminalNotificationDelivery: AnyObject {
    func configure(delegate: any UNUserNotificationCenterDelegate)
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void)
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void)
    func deliver(_ record: TerminalNotificationRecord)
    func remove(ids: [UUID])
}

@MainActor
private final class SystemTerminalNotificationDelivery: TerminalNotificationDelivery {
    // Fixtures inject delivery before the system center is ever initialized,
    // so testing native panes cannot trigger a macOS permission sheet.
    private lazy var center = UNUserNotificationCenter.current()

    func configure(delegate: any UNUserNotificationCenterDelegate) { center.delegate = delegate }

    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(.init(status: .allowed, needsSoundUpgrade: settings.soundSetting == .notSupported))
            case .notDetermined: completion(.init(status: .undetermined))
            default: completion(.init(status: .denied))
            }
        }
    }

    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Zshell: notification authorization failed: %@", String(describing: error)) }
            completion(granted)
        }
    }

    func deliver(_ record: TerminalNotificationRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Zshell"
        content.body = record.target.remoteHostName.map { "\($0): \(record.message)" } ?? record.message
        content.sound = .default
        content.userInfo = [TerminalNotificationService.recordIDKey: record.id.uuidString]
        if let id = record.target.terminalID { content.userInfo[TerminalNotificationService.sessionIDKey] = id.uuidString }
        center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)) { error in
            if let error { NSLog("Zshell: terminal notification failed: %@", String(describing: error)) }
        }
    }

    func remove(ids: [UUID]) {
        let identifiers = ids.map(\.uuidString)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

@MainActor
final class TerminalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static var shared = TerminalNotificationService()
    nonisolated static let sessionIDKey = "sessionID"
    nonisolated static let recordIDKey = "notificationID"

    let history: TerminalNotificationHistoryStore
    private let delivery: any TerminalNotificationDelivery
    private var isConfigured = false
    private var isCheckingSettings = false
    private var isRequestingAuthorization = false
    private var deliveryCandidates: [UUID] = []
    private var waitingForHistory: String?
    private var loadingAgents: [String: AgentSample] = [:]
    /// Separate windows can attach to one remote session and poll its status
    /// independently, so a lagging pane may still report an older generation.
    private var remoteGenerations: [String: UInt64] = [:]

    private struct AgentSample {
        let target: TerminalNotificationTarget
        let status: ZshellAgentStatus?
        let previous: ZshellAgentStatus?
        let isFocused: Bool
        let owner: String
        let remoteGeneration: UInt64?
        let reportedPhase: ZshellAgentPhase?
    }

    init(history: TerminalNotificationHistoryStore? = nil, delivery: (any TerminalNotificationDelivery)? = nil) {
        self.history = history ?? TerminalNotificationHistoryStore()
        self.delivery = delivery ?? SystemTerminalNotificationDelivery()
        super.init()
        self.history.onLoaded = { [weak self] in self?.historyLoaded() }
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        delivery.configure(delegate: self)
        delivery.settings { [weak self] settings in
            Task { @MainActor [weak self] in
                if settings.status == .allowed, settings.needsSoundUpgrade { self?.requestAuthorization() }
            }
        }
    }

    static func target(for sessionID: UUID?) -> TerminalNotificationTarget {
        guard let sessionID else { return .init(terminalID: nil) }
        if let context = ZshellAutomationRouter.context(forSession: sessionID), let session = context.session {
            return target(for: session, context: context)
        }
        if let session = GlobalTerminalOverlay.shared.notificationPane(for: sessionID)?.session {
            return target(for: session)
        }
        return .init(terminalID: sessionID)
    }

    static func target(for session: TerminalSession, context: ZshellAutomationRouter.PaneContext? = nil) -> TerminalNotificationTarget {
        let context = context ?? ZshellAutomationRouter.context(forSession: session.id)
        let remote = session.remoteConnection
        let quick = context == nil ? GlobalTerminalOverlay.shared.notificationPane(for: session.id) : nil
        return .init(terminalID: session.id, projectID: context?.project.id, tabID: context?.tab.id ?? quick?.tab.id,
            paneID: context?.pane.id ?? quick?.pane.id,
            projectName: AgentConversationHistoryRecord.normalizedText(context?.project.name)
                ?? (quick == nil ? nil : String(localized: "Quick Terminal")),
            tabName: AgentConversationHistoryRecord.normalizedText(context?.tab.displayTitle),
            remoteHostID: remote?.host.id, remoteSessionID: remote?.sessionID,
            remoteHostName: AgentConversationHistoryRecord.normalizedText(remote?.host.name))
    }

    func post(message: String, sessionID: UUID? = nil, kind: TerminalNotificationRecord.Kind = .terminal,
              eventKey: String? = nil, isFailure: Bool = false, notify: Bool = true) {
        post(message: message, target: Self.target(for: sessionID), kind: kind,
             eventKey: eventKey, isFailure: isFailure, isPending: false, notify: notify)
    }

    private func post(message: String, target: TerminalNotificationTarget, kind: TerminalNotificationRecord.Kind,
                      eventKey: String?, isFailure: Bool, isPending: Bool, notify: Bool) {
        let result = history.note(message: message, target: target, kind: kind, eventKey: eventKey,
                                  isFailure: isFailure, isPending: isPending)
        guard notify, result.isNew, let record = result.record else { return }
        if history.isLoading { waitingForHistory = record.eventKey }
        else { requestDelivery(id: record.id) }
    }

    func agentChanged(in session: TerminalSession, previous: ZshellAgentStatus?) {
        guard !session.hasExited, session.remoteConnection == nil || session.remoteStatus?.state == .connected else {
            terminalClosed(session)
            return
        }
        let owner = session.agentObservation.integrationOwner ?? session.agentObservation.programReport?.owner
        let identity = owner.map { "\($0.pid):\($0.startedSeconds):\($0.startedMicroseconds)" }
            ?? session.agentStatus?.processID.map { String($0) } ?? "agent"
        let sample = AgentSample(target: Self.target(for: session), status: session.agentStatus, previous: previous,
            isFocused: (TerminalManager.automationIsSessionFocused(session.id) || session.surface.hasEffectiveTerminalFocus)
                && session.surface.window?.isMiniaturized != true,
            owner: identity,
            remoteGeneration: session.remoteStatus?.agentStatus?.generation,
            reportedPhase: session.remoteStatus?.agentStatus.flatMap { ZshellAgentPhase(rawValue: $0.phase) }
                ?? session.agentObservation.programReport?.report.activityPhase)
        if history.isLoading {
            let existing = loadingAgents[sample.target.sourceKey]
            if let generation = sample.remoteGeneration, let latest = existing?.remoteGeneration, generation < latest { return }
            if loadingAgents.count < TerminalNotificationHistoryStore.maximumEpisodes || existing != nil {
                loadingAgents[sample.target.sourceKey] = sample
            }
            return
        }
        observe(sample)
    }

    private func observe(_ sample: AgentSample) {
        let source = sample.target.sourceKey
        if let generation = sample.remoteGeneration {
            if let latest = remoteGenerations[source], generation < latest { return }
            remoteGenerations[source] = generation
        }
        guard let status = sample.status else { history.resolvePending(sourceKey: source); return }
        guard status.authority == .integration || status.authority == .report || status.authority == .command else {
            history.resolvePending(sourceKey: source)
            return
        }
        let phase = sample.reportedPhase == .done ? ZshellAgentPhase.done
            : status.authority == .integration && sample.previous?.authority == .integration
                && status.phase == .idle && (sample.previous?.phase == .working || sample.previous?.phase == .blocked)
                ? .done : status.phase
        guard phase == .blocked || phase == .done else {
            history.resolvePending(sourceKey: source)
            if phase == .working || phase == .created {
                _ = history.agentEventKey(sourceKey: source, signature: "working:\(sample.owner)")
            }
            return
        }
        guard status.authority != .command else { return }
        let attention = status.attention ?? status.tasks.first(where: { $0.phase == .blocked })?.attention
        let taskID = status.tasks.first(where: { $0.phase == .blocked })?.id ?? ""
        let remoteCompletion = phase == .done ? sample.remoteGeneration.map { ":\($0)" } ?? "" : ""
        let signature = "\(sample.owner):\(status.kind.rawValue):\(phase.rawValue):\(attention?.rawValue ?? ""):\(taskID)\(remoteCompletion)"
        // A remote completion is identified by its generation, so replaying it
        // from another pane maps to the same record instead of a fresh alert.
        let stableKey = phase == .done ? sample.remoteGeneration.map { "\(source):done:\($0)" } : nil
        let key = history.agentEventKey(sourceKey: source, signature: signature, stableKey: stableKey)
        history.resolvePending(sourceKey: source, exceptEventKey: key)
        let message = phase == .blocked ? String(localized: "\(status.alias) needs attention")
            : String(localized: "\(status.alias) finished")
        post(message: message, target: sample.target, kind: .agent, eventKey: key,
             isFailure: attention == .error, isPending: phase == .blocked, notify: !sample.isFocused)
    }

    func remoteChanged(in session: TerminalSession, status: RemoteRelayStatus) {
        if status.state == .connected {
            agentChanged(in: session, previous: session.agentStatus)
            return
        }
        let target = Self.target(for: session)
        if let other = TerminalManager.connectedRemoteNotificationSession(for: target, excluding: session.id) {
            agentChanged(in: other, previous: other.agentStatus)
        } else {
            remoteGenerations[target.sourceKey] = nil
            history.resolvePending(sourceKey: target.sourceKey)
        }
        if status.state == .exited, let exitCode = status.exitCode, exitCode != 0 {
            post(message: String(localized: "Exited with status \(exitCode)"), target: target, kind: .command,
                eventKey: "\(target.sourceKey):exit", isFailure: true, isPending: false, notify: true)
        }
    }

    func terminalClosed(_ session: TerminalSession) {
        let target = Self.target(for: session)
        loadingAgents[target.sourceKey] = nil
        if let other = TerminalManager.connectedRemoteNotificationSession(for: target, excluding: session.id) {
            agentChanged(in: other, previous: other.agentStatus)
        } else {
            remoteGenerations[target.sourceKey] = nil
            history.resolvePending(sourceKey: target.sourceKey)
        }
    }

    private func historyLoaded() {
        let samples = Array(loadingAgents.values)
        loadingAgents.removeAll()
        samples.forEach(observe)
        for record in history.records where record.isPending {
            guard let session = TerminalManager.notificationSession(for: record.target), !session.hasExited,
                  session.remoteConnection == nil || session.remoteStatus?.state == .connected,
                  let status = session.agentStatus, status.phase == .blocked,
                  status.authority == .integration || status.authority == .report else {
                history.resolvePending(sourceKey: record.target.sourceKey)
                continue
            }
        }
        if let key = waitingForHistory, !history.wasRestored(eventKey: key),
           let record = history.records.first(where: { $0.eventKey == key }) { requestDelivery(id: record.id) }
        waitingForHistory = nil
    }

    private func requestDelivery(id: UUID) {
        // Only an open permission prompt coalesces to the latest banner; events
        // that arrive during a settings lookup are all still eligible.
        if isRequestingAuthorization { deliveryCandidates = [id] }
        else { deliveryCandidates = Array((deliveryCandidates + [id]).suffix(TerminalNotificationHistoryStore.maximumRecords)) }
        guard !isCheckingSettings, !isRequestingAuthorization else { return }
        isCheckingSettings = true
        delivery.settings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCheckingSettings = false
                switch settings.status {
                case .allowed:
                    if settings.needsSoundUpgrade { self.requestAuthorization() }
                    else { self.deliverCandidates() }
                case .undetermined: self.requestAuthorization()
                case .denied: self.deliveryCandidates.removeAll()
                }
            }
        }
    }

    private func requestAuthorization() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        deliveryCandidates = Array(deliveryCandidates.suffix(1))
        delivery.authorize { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequestingAuthorization = false
                if granted { self.deliverCandidates() }
                else { self.deliveryCandidates.removeAll() }
            }
        }
    }

    private func deliverCandidates() {
        let ids = deliveryCandidates
        deliveryCandidates.removeAll()
        for id in ids {
            guard let record = history.record(id: id), !record.isRead else { continue }
            delivery.deliver(record)
        }
    }

    @discardableResult
    func open(id: UUID) -> Bool {
        guard let record = history.record(id: id) else { return false }
        markRead(id: id)
        return TerminalManager.revealNotification(target: record.target)
    }

    func markRead(id: UUID) { history.markRead(id: id); delivery.remove(ids: [id]) }
    func markAllRead() { delivery.remove(ids: history.records.map(\.id)); history.markAllRead() }
    func remove(id: UUID) { delivery.remove(ids: [id]); history.remove(id: id) }
    func clear() { delivery.remove(ids: history.records.map(\.id)); history.clear() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let recordID = (info[Self.recordIDKey] as? String).flatMap(UUID.init(uuidString:))
        let sessionID = (info[Self.sessionIDKey] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            await self?.history.flush()
            if let recordID, let self, self.history.record(id: recordID) != nil {
                if !self.open(id: recordID) { TerminalNotificationCenterController.shared.show() }
            } else if let sessionID { TerminalManager.revealSession(id: sessionID) }
            else { NSApp.activate(); TerminalNotificationCenterController.shared.show() }
        }
        completionHandler()
    }
}
