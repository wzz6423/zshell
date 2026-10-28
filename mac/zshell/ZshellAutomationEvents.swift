import AppKit
import Foundation

/// Subscriptions keep their original window and project. Model mutations are
/// the source of events; no timer or terminal-output scan drives this stream.
@MainActor
final class ZshellAutomationEventHub {
    static let shared = ZshellAutomationEventHub()
    nonisolated static let eventNames: Set<String> = [
        "session.created", "session.closed", "pane.created", "pane.closed", "pane.updated", "focus.changed",
        "agent.status", "agent.progress", "agent.attention", "agent.finished",
        "command.finished", "command.task.finished",
    ]

    private struct PaneRecord: Equatable {
        let tabID: UUID
        let paneID: UUID
        let terminalID: UUID?
        let contentID: UUID
        let content: String
        let remoteHostID: UUID?
        let remoteSessionID: UUID?

        var data: [String: ZshellJSONValue] {
            ["tab_id": .string(tabID.uuidString), "pane_id": .string(paneID.uuidString),
             "terminal_id": terminalID.map { .string($0.uuidString) } ?? .null,
             "content_id": .string(contentID.uuidString), "content": .string(content),
             "host_id": remoteHostID.map { .string($0.uuidString) } ?? .null,
             "remote_session_id": remoteSessionID.map { .string($0.uuidString) } ?? .null]
        }
    }

    private final class Subscription {
        let id = UUID()
        let callerID: UUID
        let projectID: UUID
        let managerID: ObjectIdentifier
        let paneID: UUID?
        let events: Set<String>
        weak var connection: ZshellAutomationEventConnection?
        var panes: [UUID: PaneRecord]
        var focus: ZshellJSONValue
        var sequence = 0

        init(caller: ZshellAutomationRouter.PaneContext, paneID: UUID?, events: Set<String>,
             connection: ZshellAutomationEventConnection) {
            callerID = caller.session!.id
            projectID = caller.project.id
            managerID = ObjectIdentifier(caller.manager)
            self.paneID = paneID
            self.events = events
            self.connection = connection
            panes = ZshellAutomationEventHub.records(caller)
            focus = ZshellAutomationEventHub.focus(caller)
        }
    }

    private var subscriptions: [UUID: Subscription] = [:]
    private var topologyChangeDepth = 0
    private var topologyChangedDuringTransaction = false
    private var focusObservers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { Self.shared.topologyChanged() } })
        }
    }

    func subscribe(_ request: ZshellAutomationRequest, connection: ZshellAutomationEventConnection) {
        prune()
        guard !connection.isClosed else { return }
        guard let id = UUID(uuidString: request.terminalID),
              let caller = ZshellAutomationRouter.context(forSession: id) else {
            connection.finish(.failure(id: request.id, code: "caller_closed",
                                       message: "The terminal that owned this capability is no longer open."))
            return
        }
        guard Set(request.params.keys).isSubset(of: ["pane_id", "events"]),
              request.params["pane_id"] == nil || UUID(uuidString: request.params["pane_id"]?.stringValue ?? "") != nil,
              request.params["events"] == nil || request.params["events"]?.arrayValue != nil else {
            connection.finish(.failure(id: request.id, code: "invalid_params", message: "Use pane_id and events to filter an event subscription."))
            return
        }
        let names = request.params["events"]?.arrayValue ?? []
        let events = Set(names.compactMap(\.stringValue))
        guard names.count <= Self.eventNames.count, events.count == names.count,
              events.isSubset(of: Self.eventNames) else {
            connection.finish(.failure(id: request.id, code: "invalid_params", message: "Unknown or duplicate automation event name."))
            return
        }
        let paneID = request.params["pane_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if let paneID, !caller.project.tabs.contains(where: { $0.allPanes.contains { $0.id == paneID } }) {
            connection.finish(.failure(id: request.id, code: "pane_not_found", message: "No matching pane exists in this project."))
            return
        }
        guard subscriptions.count < ZshellAutomationEventConnection.maximumSubscriptions else {
            connection.finish(.failure(id: request.id, code: "subscription_limit", message: "Zshell already has 32 event subscriptions."))
            return
        }
        let subscription = Subscription(caller: caller, paneID: paneID, events: events, connection: connection)
        subscriptions[subscription.id] = subscription
        connection.setLagFrame(frame(subscription, event: "stream.lagged", data: [
            "reason": .string("queue_limit"), "requires_resubscribe": .bool(true),
        ]))
        connection.reply(.success(id: request.id, result: frame(subscription, event: "stream.ready", data: [
            "queue_frames": .number(Double(ZshellAutomationEventConnection.maximumQueuedFrames)),
            "queue_bytes": .number(Double(ZshellAutomationEventConnection.maximumQueuedBytes)),
            "frame_bytes": .number(Double(ZshellAutomationEventConnection.maximumFrameBytes)),
            "replay": .bool(false),
        ])))
    }

    func revoke(terminalID: UUID) {
        for subscription in Array(subscriptions.values) where subscription.callerID == terminalID {
            subscription.connection?.close()
            subscriptions[subscription.id] = nil
        }
    }

    func beginTopologyChange() { topologyChangeDepth += 1 }

    func endTopologyChange() {
        topologyChangeDepth -= 1
        if topologyChangeDepth == 0, topologyChangedDuringTransaction {
            topologyChangedDuringTransaction = false
            topologyChanged()
        }
    }

    func topologyChanged() {
        guard topologyChangeDepth == 0 else {
            topologyChangedDuringTransaction = true
            return
        }
        prune()
        for subscription in Array(subscriptions.values) {
            guard let caller = validCaller(subscription) else { continue }
            let next = Self.records(caller)
            for record in subscription.panes.values.filter({ next[$0.paneID] == nil })
                .sorted(by: { $0.paneID.uuidString < $1.paneID.uuidString }) {
                emit(subscription, event: "pane.closed", record: record)
                if record.terminalID != nil { emit(subscription, event: "session.closed", record: record) }
            }
            for record in next.values.filter({ subscription.panes[$0.paneID] == nil })
                .sorted(by: { $0.paneID.uuidString < $1.paneID.uuidString }) {
                if record.terminalID != nil { emit(subscription, event: "session.created", record: record) }
                emit(subscription, event: "pane.created", record: record)
            }
            for record in next.values {
                guard let previous = subscription.panes[record.paneID], previous != record else { continue }
                if previous.terminalID != record.terminalID {
                    if previous.terminalID != nil { emit(subscription, event: "session.closed", record: previous) }
                    if record.terminalID != nil { emit(subscription, event: "session.created", record: record) }
                }
                emit(subscription, event: "pane.updated", record: record, data: ["from": .object(previous.data)])
            }
            subscription.panes = next
            let focus = Self.focus(caller)
            if focus != subscription.focus {
                let record = caller.project.selectedTab?.focusedPane.flatMap { next[$0.id] }
                emit(subscription, event: "focus.changed", record: record,
                     data: ["from": subscription.focus, "to": focus])
                subscription.focus = focus
            }
        }
    }

    func agentChanged(in session: TerminalSession, previous: ZshellAgentStatus?) {
        guard !subscriptions.isEmpty else { return }
        let status = session.agentStatus
        let snapshot = status.map(ZshellAutomationRouter.agentSnapshot) ?? .null
        publish(sessionID: session.id, event: "agent.status", data: ["agent": snapshot])
        if status?.progress != previous?.progress {
            publish(sessionID: session.id, event: "agent.progress", data: ["agent": snapshot])
        }
        if status?.attention != previous?.attention || (status?.phase == .blocked && previous?.phase != .blocked) {
            publish(sessionID: session.id, event: "agent.attention", data: ["agent": snapshot])
        }
        if let status, status.authority != .screen, status.authority != .report,
           (status.phase == .done && previous?.phase != .done
            || status.phase == .idle && (previous?.phase == .working || previous?.phase == .blocked)) {
            publish(sessionID: session.id, event: "agent.finished", data: ["agent": snapshot])
        }
    }

    func agentReportFinished(in session: TerminalSession) {
        publish(sessionID: session.id, event: "agent.finished", data: [
            "agent": session.agentStatus.map(ZshellAutomationRouter.agentSnapshot) ?? .null,
        ])
    }

    func commandFinished(in session: TerminalSession) {
        publish(sessionID: session.id, event: "command.finished", data: [
            "completion_sequence": .number(Double(session.commandLifecycle.completionSequence)),
            "exit_code": session.commandLifecycle.lastExitCode.map { .number(Double($0)) } ?? .null,
            "duration_ms": session.commandLifecycle.lastDurationNanos.map { .number(Double($0) / 1_000_000) } ?? .null,
        ])
    }

    func commandTaskFinished(_ task: TerminalCommandTask) {
        // Results stay in the task store. Streaming only metadata avoids
        // multiplying retained terminal output by the subscription count.
        publish(sessionID: task.terminalID, event: "command.task.finished", projectID: task.projectID, data: [
            "task_id": .string(task.id.uuidString), "state": .string(task.state.rawValue),
            "exit_code": task.exitCode.map { .number(Double($0)) } ?? .null,
            "duration_ms": task.durationNanos.map { .number(Double($0) / 1_000_000) } ?? .null,
            "error_code": task.errorCode.map(ZshellJSONValue.string) ?? .null,
        ])
    }

    private func publish(sessionID: UUID, event: String, projectID: UUID? = nil,
                         data: [String: ZshellJSONValue]) {
        prune()
        for subscription in Array(subscriptions.values) {
            guard projectID == nil || subscription.projectID == projectID,
                  let caller = validCaller(subscription),
                  let context = ZshellAutomationRouter.projectContexts(caller.project, manager: caller.manager)
                    .first(where: { $0.session?.id == sessionID }) else { continue }
            emit(subscription, event: event, record: Self.record(context), data: data)
        }
    }

    private func validCaller(_ subscription: Subscription) -> ZshellAutomationRouter.PaneContext? {
        guard let caller = ZshellAutomationRouter.context(forSession: subscription.callerID),
              caller.project.id == subscription.projectID,
              ObjectIdentifier(caller.manager) == subscription.managerID else {
            subscription.connection?.close()
            subscriptions[subscription.id] = nil
            return nil
        }
        return caller
    }

    private func prune() {
        subscriptions = subscriptions.filter { $0.value.connection?.isClosed == false }
    }

    private func emit(_ subscription: Subscription, event: String, record: PaneRecord?,
                      data: [String: ZshellJSONValue] = [:]) {
        guard subscription.events.isEmpty || subscription.events.contains(event),
              subscription.paneID == nil || subscription.paneID == record?.paneID
                || event == "focus.changed" && data["from"]?.objectValue?["pane_id"]?.stringValue == subscription.paneID?.uuidString
        else { return }
        subscription.sequence += 1
        subscription.connection?.send(frame(subscription, event: event,
                                            data: (record?.data ?? [:]).merging(data) { _, new in new }))
    }

    private func frame(_ subscription: Subscription, event: String,
                       data: [String: ZshellJSONValue]) -> ZshellJSONValue {
        .object([
            "version": .number(1), "event": .string(event),
            "stream_id": .string(subscription.id.uuidString),
            "sequence": .number(Double(subscription.sequence)),
            "time": .number(Date().timeIntervalSince1970 * 1_000),
            "project_id": .string(subscription.projectID.uuidString), "data": .object(data),
        ])
    }

    private static func records(_ caller: ZshellAutomationRouter.PaneContext) -> [UUID: PaneRecord] {
        Dictionary(ZshellAutomationRouter.projectContexts(caller.project, manager: caller.manager)
            .map { let value = record($0); return (value.paneID, value) }, uniquingKeysWith: { _, new in new })
    }

    private static func record(_ context: ZshellAutomationRouter.PaneContext) -> PaneRecord {
        let content: String = switch context.pane.content {
        case .session: "terminal"
        case .file: "file"
        case .browser: "browser"
        case .diff: "diff"
        }
        return PaneRecord(tabID: context.tab.id, paneID: context.pane.id, terminalID: context.session?.id,
                          contentID: context.pane.content.id, content: content,
                          remoteHostID: context.session?.remoteConnection?.host.id,
                          remoteSessionID: context.session?.remoteConnection?.sessionID)
    }

    private static func focus(_ caller: ZshellAutomationRouter.PaneContext) -> ZshellJSONValue {
        guard caller.manager.selectedProjectID == caller.project.id,
              let tab = caller.project.selectedTab else { return .null }
        return .object([
            "tab_id": .string(tab.id.uuidString), "pane_id": .string(tab.focusedPaneID.uuidString),
            "window_key": .bool(caller.manager.presentationWindow?.isKeyWindow == true && NSApp.isActive),
        ])
    }
}
