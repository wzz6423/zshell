import AppKit
import Combine
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeController: nonisolated ObservableObject {
    static let shared = KeepAwakeController()

    struct Assertions {
        var create: () -> (IOReturn, IOPMAssertionID)
        var release: (IOPMAssertionID) -> IOReturn

        static let system = Assertions(create: {
            var id: IOPMAssertionID = 0
            // Idle sleep is the only constraint: displays, lid close, and
            // explicit sleep must keep following macOS policy.
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Zshell keep computer awake" as CFString,
                &id
            )
            return (result, id)
        }, release: { IOPMAssertionRelease($0) })
    }

    @Published private(set) var isActive = false
    @Published private(set) var lastError: IOReturn?
    private var assertionID: IOPMAssertionID?
    private let assertions: Assertions
    private let now: () -> Date
    private var mode = KeepAwakeMode.off
    private var hasWorkingLocalAgent = false
    private var isRunning = false
    private var isSleeping = false
    private var nextRetry = Date.distantPast
    private var settingsObservation: AnyCancellable?
    private var retryTimer: Timer?
    private var workspaceObservations: [NSObjectProtocol] = []

    init(assertions: Assertions? = nil, now: @escaping () -> Date = Date.init) {
        self.assertions = assertions ?? .system
        self.now = now
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hasWorkingLocalAgent = AgentAutomationMonitor.shared.hasWorkingLocalAgent
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.isSleeping = notification.name == NSWorkspace.willSleepNotification
                    self?.nextRetry = .distantPast
                    self?.reconcile()
                }
            })
        }
        settingsObservation = AppSettings.shared.$keepAwakeMode.removeDuplicates().sink { [weak self] mode in
            guard let self else { return }
            self.mode = mode
            self.nextRetry = .distantPast
            self.reconcile()
        }
    }

    func stop() {
        isRunning = false
        settingsObservation = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservations.forEach(center.removeObserver)
        workspaceObservations.removeAll()
        nextRetry = .distantPast
        reconcile()
    }

    func localAgentActivityChanged(_ working: Bool) {
        if working != hasWorkingLocalAgent { nextRetry = .distantPast }
        hasWorkingLocalAgent = working
        reconcile()
    }

    var statusDescription: String {
        if let lastError {
            return isActive
                ? String(localized: "Could not stop sleep prevention (error \(lastError)).")
                : String(localized: "Sleep prevention is unavailable (error \(lastError)).")
        }
        if isActive {
            return String(localized: "Automatic system sleep is prevented. The display can sleep; manual sleep is still available.")
        }
        if mode == .whileAgentsWork, !isSleeping, isRunning {
            return String(localized: "Waiting for a local agent to work. The Mac can sleep.")
        }
        return String(localized: "The Mac can sleep automatically.")
    }

    private func reconcile() {
        let hold = isRunning && !isSleeping && (mode == .whileRunning
            || mode == .whileAgentsWork && hasWorkingLocalAgent)
        guard hold != (assertionID != nil) else {
            if lastError != nil { lastError = nil }
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard now() >= nextRetry else { return }
        let result: IOReturn
        if hold {
            let (created, id) = assertions.create()
            result = created
            if result == kIOReturnSuccess { assertionID = id }
        } else if let id = assertionID {
            result = assertions.release(id)
            if result == kIOReturnSuccess { assertionID = nil }
        } else {
            return
        }
        let active = assertionID != nil
        if isActive != active { isActive = active }
        let error = result == kIOReturnSuccess ? nil : result
        if lastError != error {
            lastError = error
            if let error { NSLog("zshell: keep-awake assertion failed: %d", error) }
        }
        nextRetry = result == kIOReturnSuccess ? .distantPast : now().addingTimeInterval(5)
        retryTimer?.invalidate()
        retryTimer = nil
        if result != kIOReturnSuccess {
            let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retryTimer = nil
                    self?.reconcile()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
    }

    isolated deinit {
        settingsObservation = nil
        retryTimer?.invalidate()
        workspaceObservations.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let assertionID { _ = assertions.release(assertionID) }
    }
}
