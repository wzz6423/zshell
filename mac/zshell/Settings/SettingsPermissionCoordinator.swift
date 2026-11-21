import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics

@MainActor
final class SettingsPermissionCoordinator: ObservableObject {
    typealias Completion = @MainActor @Sendable (SettingsPermissionStatus) -> Void
    typealias RequestCompletion = @MainActor @Sendable (Result<SettingsPermissionStatus, Error>) -> Void

    struct Dependencies {
        var read: (SettingsPermission, @escaping Completion) -> Void
        var request: (SettingsPermission, @escaping RequestCompletion) -> Void
        var openSettings: (URL) -> Bool
    }

    enum Failure {
        case request, openSettings

        var title: String {
            switch self {
            case .request: String(localized: "Could not request permission. Try again.")
            case .openSettings: String(localized: "Could not open System Settings. Open it manually.")
            }
        }
    }

    @Published private(set) var statuses = Dictionary(
        uniqueKeysWithValues: SettingsPermission.allCases.map {
            ($0, $0.requiresSystemSettings ? SettingsPermissionStatus.manual : .notDetermined)
        })
    @Published private(set) var failures: [SettingsPermission: Failure] = [:]
    @Published private(set) var requesting: SettingsPermission?
    var onOpenSettings: ((SettingsPermission) -> Void)?

    private let dependencies: Dependencies
    private var isActive = false
    private var refreshGeneration = UUID()
    private var requestGeneration = UUID()

    convenience init() {
        self.init(
            dependencies: Dependencies(
                read: SystemSettingsPermissions.read,
                request: SystemSettingsPermissions.request,
                openSettings: { NSWorkspace.shared.open($0) }
            ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func activate() {
        isActive = true
        refresh()
    }

    func deactivate() {
        isActive = false
        refreshGeneration = UUID()
        // macOS owns an outstanding permission prompt; keep it serialized until it answers.
    }

    func refresh() {
        guard isActive else { return }
        refreshGeneration = UUID()
        let generation = refreshGeneration
        for permission in SettingsPermission.allCases where permission != requesting {
            dependencies.read(permission) { [weak self] status in
                guard let self, self.isActive, self.refreshGeneration == generation,
                    self.requesting != permission
                else { return }
                self.update(permission, status: status)
            }
        }
    }

    func performAction(for permission: SettingsPermission) {
        guard isActive, requesting == nil, let status = statuses[permission] else { return }
        failures[permission] = nil
        switch status {
        case .denied, .restricted, .manual, .granted:
            openSettings(for: permission)
        case .requesting:
            return
        case .notDetermined, .unavailable:
            request(permission, previous: status)
        }
    }

    private func request(_ permission: SettingsPermission, previous: SettingsPermissionStatus) {
        refreshGeneration = UUID()
        requestGeneration = UUID()
        let generation = requestGeneration
        requesting = permission
        statuses[permission] = .requesting
        // Recheck after the click so a stale row never requests a permission already changed in Settings.
        dependencies.read(permission) { [weak self] status in
            guard let self, self.requestGeneration == generation, self.requesting == permission else { return }
            guard self.isActive else {
                self.requesting = nil
                self.update(permission, status: status)
                return
            }
            guard status == .notDetermined || status == .unavailable else {
                self.requesting = nil
                self.update(permission, status: status)
                if status != .granted { self.openSettings(for: permission) }
                return
            }
            self.dependencies.request(permission) { [weak self] result in
                guard let self, self.requestGeneration == generation, self.requesting == permission else { return }
                self.requesting = nil
                switch result {
                case .success(let status):
                    self.update(permission, status: status)
                    if self.isActive, permission.hasBooleanPreflight, status != .granted {
                        self.openSettings(for: permission)
                    }
                case .failure:
                    self.statuses[permission] = previous
                    self.failures[permission] = .request
                }
            }
        }
    }

    private func openSettings(for permission: SettingsPermission) {
        guard dependencies.openSettings(permission.settingsURL) else {
            failures[permission] = .openSettings
            return
        }
        onOpenSettings?(permission)
    }

    private func update(_ permission: SettingsPermission, status: SettingsPermissionStatus) {
        // Boolean preflight APIs cannot distinguish a denial from a permission never requested.
        if permission.hasBooleanPreflight, status == .notDetermined, statuses[permission] == .denied { return }
        statuses[permission] = status
    }
}

@MainActor
private enum SystemSettingsPermissions {
    static func read(_ permission: SettingsPermission, completion: @escaping SettingsPermissionCoordinator.Completion) {
        switch permission {
        case .notifications:
            TerminalNotificationService.shared.readAuthorization { authorization in
                Task { @MainActor in
                    let status: SettingsPermissionStatus
                    switch authorization.status {
                    case .allowed: status = .granted
                    case .undetermined: status = .notDetermined
                    case .denied: status = .denied
                    }
                    completion(status)
                }
            }
        case .accessibility:
            completion(AXIsProcessTrusted() ? .granted : .notDetermined)
        case .inputMonitoring:
            completion(CGPreflightListenEventAccess() ? .granted : .notDetermined)
        case .screenRecording:
            completion(CGPreflightScreenCaptureAccess() ? .granted : .notDetermined)
        case .camera, .microphone:
            switch AVCaptureDevice.authorizationStatus(for: permission == .camera ? .video : .audio) {
            case .authorized: completion(.granted)
            case .notDetermined: completion(.notDetermined)
            case .denied: completion(.denied)
            case .restricted: completion(.restricted)
            @unknown default: completion(.unavailable)
            }
        case .automation, .filesAndFolders, .fullDiskAccess:
            // These grants are target-specific or have no public authorization status API.
            completion(.manual)
        }
    }

    static func request(_ permission: SettingsPermission, completion: @escaping SettingsPermissionCoordinator.RequestCompletion) {
        switch permission {
        case .notifications:
            TerminalNotificationService.shared.requestAuthorization { granted in
                completion(.success(granted ? .granted : .denied))
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            completion(.success(AXIsProcessTrustedWithOptions(options) ? .granted : .denied))
        case .inputMonitoring:
            completion(.success(CGRequestListenEventAccess() ? .granted : .denied))
        case .screenRecording:
            completion(.success(CGRequestScreenCaptureAccess() ? .granted : .denied))
        case .camera, .microphone:
            AVCaptureDevice.requestAccess(for: permission == .camera ? .video : .audio) { granted in
                Task { @MainActor in completion(.success(granted ? .granted : .denied)) }
            }
        case .automation, .filesAndFolders, .fullDiskAccess:
            completion(.success(.manual))
        }
    }
}
