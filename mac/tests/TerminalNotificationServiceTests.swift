import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationDeliveryFixture: TerminalNotificationDelivery {
    var current = TerminalNotificationAuthorization(status: .denied)
    var authorizationRequests = 0
    var settingsRequests = 0
    var authorization: (@Sendable (Bool) -> Void)?
    var delivered: [TerminalNotificationRecord] = []
    var removed: [UUID] = []

    func configure(delegate: any UNUserNotificationCenterDelegate) {}
    func settings(_ completion: @escaping @Sendable (TerminalNotificationAuthorization) -> Void) {
        settingsRequests += 1
        completion(current)
    }
    func authorize(_ completion: @escaping @Sendable (Bool) -> Void) {
        authorizationRequests += 1
        authorization = completion
    }
    func deliver(_ record: TerminalNotificationRecord) { delivered.append(record) }
    func remove(ids: [UUID]) { removed += ids }
}

@main
@MainActor
struct TerminalNotificationServiceTests {
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let history = TerminalNotificationHistoryStore(url: root.appendingPathComponent("service/records.json"))
        let delivery = NotificationDeliveryFixture()
        let service = TerminalNotificationService(history: history, delivery: delivery)
        await history.flush()
        service.configure()
        await settle()
        for index in 0..<250 { service.post(message: "Event \(index)", sessionID: UUID()) }
        await settle()
        precondition(history.records.count == 200 && delivery.delivered.isEmpty && delivery.authorizationRequests == 0)
        service.markAllRead()
        await history.flush()
        precondition(history.filtered(.unread).isEmpty)
        print("PASS denied system permissions preserve bounded app history and never request authorization")

        delivery.current = .init(status: .undetermined)
        service.post(message: "Permission fixture", sessionID: UUID())
        await settle()
        for index in 0..<300 { service.post(message: "Pending \(index)", sessionID: UUID()) }
        await settle()
        precondition(delivery.authorizationRequests == 1)
        delivery.authorization?(true)
        await settle()
        precondition(delivery.delivered.count == 1 && delivery.delivered.last?.message == "Pending 299")
        print("PASS permission request storm retains only the latest banner and one authorization request")

        delivery.current = .init(status: .allowed)
        let session = TerminalSession()
        func update(_ phase: ZshellAgentPhase, authority: ZshellAgentStateAuthority = .integration,
                    attention: ZshellAgentAttention? = nil, progress: Int? = nil) {
            let previous = session.agentStatus
            session.agentStatus = ZshellAgentStatus(alias: "Fixture Agent", kind: .codex, phase: phase,
                authority: authority, reason: "fixture", updatedAt: Date(), processID: nil,
                unseen: phase == .done, progress: progress, attention: attention, tasks: [])
            service.agentChanged(in: session, previous: previous)
        }
        let before = history.records.count
        update(.blocked, authority: .screen, attention: .approval)
        precondition(history.records.count == before && history.filtered(.pending).isEmpty)
        update(.working)
        update(.blocked, attention: .approval)
        let waiting = history.filtered(.pending).first!
        update(.blocked, attention: .approval, progress: 40)
        await settle()
        precondition(history.filtered(.pending).count == 1 && history.filtered(.pending)[0].id == waiting.id)
        service.markRead(id: waiting.id)
        update(.blocked, attention: .approval, progress: 41)
        precondition(history.record(id: waiting.id)?.isRead == true)
        update(.blocked, authority: .screen, attention: .approval)
        precondition(history.filtered(.pending).isEmpty)
        update(.blocked, attention: .approval)
        precondition(history.filtered(.pending).count == 1 && history.record(id: waiting.id)?.isRead == true)
        update(.working)
        precondition(history.filtered(.pending).isEmpty)
        update(.blocked, attention: .error)
        precondition(history.filtered(.failed).contains { $0.kind == .agent })
        update(.working)
        update(.idle)
        precondition(history.records.contains { $0.kind == .agent && $0.message.contains("finished") })
        update(.blocked, attention: .input)
        session.hasExited = true
        service.terminalClosed(session)
        precondition(history.filtered(.pending).isEmpty)
        print("PASS explicit lifecycle: screen hints ignored, progress deduplicated, read state stable, pending resolved, errors classified")

        service.clear()
        let replaySession = TerminalSession()
        replaySession.agentStatus = ZshellAgentStatus(alias: "Fixture Agent", kind: .codex, phase: .blocked,
            authority: .report, reason: "fixture", updatedAt: Date(), processID: nil,
            unseen: false, progress: nil, attention: .input, tasks: [])
        service.agentChanged(in: replaySession, previous: nil)
        let record = history.filtered(.pending).first!
        service.markRead(id: record.id)
        await history.flush()
        let resumedHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("service/records.json"))
        let resumedDelivery = NotificationDeliveryFixture()
        let resumedService = TerminalNotificationService(history: resumedHistory, delivery: resumedDelivery)
        await resumedHistory.flush()
        resumedService.agentChanged(in: replaySession, previous: nil)
        precondition(resumedHistory.records.count == 1 && resumedHistory.records[0].isRead)
        resumedService.clear()
        resumedService.agentChanged(in: replaySession, previous: nil)
        precondition(resumedHistory.records.isEmpty)
        await resumedHistory.flush()
        print("PASS persisted agent episode replay neither duplicates read history nor resurrects cleared history")

        let remoteHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("remote/records.json"))
        let remoteService = TerminalNotificationService(history: remoteHistory, delivery: NotificationDeliveryFixture())
        await remoteHistory.flush()
        let host = RemoteHost(id: UUID(), name: "Fixture host")
        let remoteID = UUID()
        let first = TerminalSession(), second = TerminalSession()
        let blocked = ZshellAgentStatus(alias: "Remote agent", kind: .codex, phase: .blocked,
            authority: .report, reason: "fixture", updatedAt: Date(), processID: nil,
            unseen: false, progress: nil, attention: .input, tasks: [])
        let connected = RemoteRelayStatus(state: .connected, agentStatus: nil, exitCode: nil)
        let disconnected = RemoteRelayStatus(state: .failed, agentStatus: nil, exitCode: nil)
        for session in [first, second] {
            session.remoteConnection = RemoteConnection(host: host, sessionID: remoteID)
            session.remoteStatus = connected
            session.agentStatus = blocked
        }
        remoteService.agentChanged(in: first, previous: nil)
        let pending = remoteHistory.filtered(.pending).first!
        remoteService.markRead(id: pending.id)
        TerminalManager.connectedRemoteSession = second
        first.remoteStatus = disconnected
        remoteService.remoteChanged(in: first, status: disconnected)
        precondition(remoteHistory.filtered(.pending).count == 1 && remoteHistory.records.count == 1)
        remoteService.terminalClosed(first)
        precondition(remoteHistory.filtered(.pending).count == 1 && remoteHistory.record(id: pending.id)?.isRead == true)
        second.remoteStatus = disconnected
        remoteService.remoteChanged(in: second, status: disconnected)
        precondition(remoteHistory.filtered(.pending).isEmpty)
        second.remoteStatus = connected
        remoteService.remoteChanged(in: second, status: connected)
        precondition(remoteHistory.filtered(.pending).count == 1 && remoteHistory.records.count == 1
            && remoteHistory.record(id: pending.id)?.isRead == true)
        let exited = RemoteRelayStatus(state: .exited, agentStatus: nil, exitCode: 7)
        second.remoteStatus = exited
        remoteService.remoteChanged(in: second, status: exited)
        remoteService.remoteChanged(in: second, status: exited)
        precondition(remoteHistory.filtered(.pending).isEmpty && remoteHistory.filtered(.failed).count == 1)
        TerminalManager.connectedRemoteSession = nil
        await remoteHistory.flush()
        print("PASS shared remote disconnect, reconnect, read-state stability, and deduplicated exit")

        let focusHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("focus/records.json"))
        let focusDelivery = NotificationDeliveryFixture()
        focusDelivery.current = .init(status: .allowed)
        let focusService = TerminalNotificationService(history: focusHistory, delivery: focusDelivery)
        await focusHistory.flush()
        let minimized = TerminalSession()
        minimized.surface = Surface(hasEffectiveTerminalFocus: true, window: Window(isMiniaturized: true))
        minimized.agentStatus = blocked
        focusService.agentChanged(in: minimized, previous: nil)
        await settle()
        precondition(focusDelivery.delivered.count == 1 && focusHistory.filtered(.pending).count == 1)
        minimized.surface.window = Window(isMiniaturized: false)
        let previous = minimized.agentStatus
        minimized.agentStatus = ZshellAgentStatus(alias: "Remote agent", kind: .codex, phase: .done,
            authority: .report, reason: "fixture", updatedAt: Date(), processID: nil,
            unseen: false, progress: nil, attention: nil, tasks: [])
        focusService.agentChanged(in: minimized, previous: previous)
        await settle()
        precondition(focusDelivery.delivered.count == 1 && focusHistory.records.count == 2)
        await focusHistory.flush()
        print("PASS minimized focused pane delivers a banner while a visible focused pane only records history")

        let burstHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("burst/records.json"))
        let burstDelivery = NotificationDeliveryFixture()
        burstDelivery.current = .init(status: .allowed)
        let burstService = TerminalNotificationService(history: burstHistory, delivery: burstDelivery)
        await burstHistory.flush()
        burstService.post(message: "First command finished", sessionID: UUID())
        burstService.post(message: "Second command finished", sessionID: UUID())
        await settle()
        precondition(burstDelivery.delivered.map(\.message) == ["First command finished", "Second command finished"])
        await burstHistory.flush()
        print("PASS granted permission delivers every banner posted during one settings lookup")

        let staleHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("stale/records.json"))
        var staleService = TerminalNotificationService(history: staleHistory, delivery: NotificationDeliveryFixture())
        await staleHistory.flush()
        let staleID = UUID()
        let leading = TerminalSession(), lagging = TerminalSession()
        func remote(_ session: TerminalSession, _ phase: ZshellAgentPhase, generation: UInt64) {
            let previous = session.agentStatus
            session.remoteConnection = RemoteConnection(host: host, sessionID: staleID)
            session.remoteStatus = RemoteRelayStatus(state: .connected,
                agentStatus: RemoteAgentStatus(generation: generation, phase: phase.rawValue), exitCode: nil)
            session.agentStatus = ZshellAgentStatus(alias: "Remote agent", kind: .codex, phase: phase,
                authority: .report, reason: "fixture", updatedAt: Date(), processID: nil,
                unseen: phase == .done, progress: nil, attention: nil, tasks: [])
            staleService.agentChanged(in: session, previous: previous)
        }
        remote(leading, .done, generation: 4)
        let finished = staleHistory.records.first!
        staleService.markRead(id: finished.id)
        remote(leading, .working, generation: 5)
        remote(lagging, .done, generation: 4)
        precondition(staleHistory.records.count == 1 && staleHistory.records[0].isRead)
        staleService.clear()
        remote(leading, .done, generation: 4)
        precondition(staleHistory.records.isEmpty)
        remote(leading, .done, generation: 6)
        precondition(staleHistory.records.count == 1 && !staleHistory.records[0].isRead)
        staleService.clear()
        await staleHistory.flush()
        // A relaunched app has no generation watermark; the stable key still
        // keeps a replayed, already-cleared completion from coming back.
        let relaunchedHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("stale/records.json"))
        staleService = TerminalNotificationService(history: relaunchedHistory, delivery: NotificationDeliveryFixture())
        await relaunchedHistory.flush()
        remote(lagging, .working, generation: 3)
        remote(lagging, .done, generation: 4)
        precondition(relaunchedHistory.records.isEmpty)
        await relaunchedHistory.flush()
        print("PASS stale remote generations from another pane neither resurrect read nor cleared completions")

        let reportedHistory = TerminalNotificationHistoryStore(url: root.appendingPathComponent("reported/records.json"))
        let reportedService = TerminalNotificationService(history: reportedHistory, delivery: NotificationDeliveryFixture())
        await reportedHistory.flush()
        let reported = TerminalSession()
        reported.agentObservation.programReport = Observation(owner: ProcessIdentity(pid: 41, startedSeconds: 1, startedMicroseconds: 0),
                                                              report: Report(activityPhase: .done))
        func native(_ phase: ZshellAgentPhase, authority: ZshellAgentStateAuthority = .integration, attention: ZshellAgentAttention? = nil) {
            let previous = reported.agentStatus
            reported.agentStatus = ZshellAgentStatus(alias: "Native Agent", kind: .codex, phase: phase,
                authority: authority, reason: "fixture", updatedAt: Date(), processID: 41,
                unseen: false, progress: nil, attention: attention, tasks: [])
            reportedService.agentChanged(in: reported, previous: previous)
        }
        native(.working)
        native(.blocked, attention: .approval)
        precondition(reportedHistory.filtered(.pending).count == 1)
        precondition(!reportedHistory.records.contains { $0.message.contains("finished") })
        native(.working)
        precondition(reportedHistory.filtered(.pending).isEmpty && reportedHistory.records.count == 1)
        native(.working, authority: .report)
        precondition(reportedHistory.records.contains { $0.message.contains("finished") })
        await reportedHistory.flush()
        print("PASS a live program report does not turn a native agent's working or blocked states into completions")
    }
}
