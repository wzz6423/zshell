import Foundation

nonisolated enum SettingsPermission: String, CaseIterable, Sendable {
    case notifications
    case accessibility
    case inputMonitoring
    case screenRecording
    case camera
    case microphone
    case automation
    case filesAndFolders
    case fullDiskAccess

    var title: String {
        switch self {
        case .notifications: String(localized: "Notifications")
        case .accessibility: String(localized: "Accessibility")
        case .inputMonitoring: String(localized: "Input Monitoring")
        case .screenRecording: String(localized: "Screen Recording")
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .automation: String(localized: "Automation")
        case .filesAndFolders: String(localized: "Files and Folders")
        case .fullDiskAccess: String(localized: "Full Disk Access")
        }
    }

    var explanation: String {
        switch self {
        case .notifications:
            String(localized: "Notify you when commands finish or agents need attention.")
        case .accessibility:
            String(localized: "Let programs and agents running in Zshell control other apps.")
        case .inputMonitoring:
            String(localized: "Let programs running in Zshell observe keyboard and mouse input outside the app.")
        case .screenRecording:
            String(localized: "Let programs and agents running in Zshell capture the screen.")
        case .camera:
            String(localized: "Let programs running in Zshell use the camera.")
        case .microphone:
            String(localized: "Let programs running in Zshell record microphone audio.")
        case .automation:
            String(localized: "Let scripts running in Zshell send Apple events to other apps. macOS asks for each target app when a script runs.")
        case .filesAndFolders:
            String(localized: "Let Zshell and its terminal programs access protected folders. macOS asks when a program first accesses a folder.")
        case .fullDiskAccess:
            String(localized: "Access protected files and browser data for import. Add Zshell in System Settings and restart it if macOS asks.")
        }
    }

    var symbolName: String {
        switch self {
        case .notifications: "bell"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        case .screenRecording: "rectangle.on.rectangle"
        case .camera: "camera"
        case .microphone: "mic"
        case .automation: "applescript"
        case .filesAndFolders: "folder"
        case .fullDiskAccess: "externaldrive"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .notifications: pane = "com.apple.preference.notifications"
        case .accessibility: pane = "com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: pane = "com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording: pane = "com.apple.preference.security?Privacy_ScreenCapture"
        case .camera: pane = "com.apple.preference.security?Privacy_Camera"
        case .microphone: pane = "com.apple.preference.security?Privacy_Microphone"
        case .automation: pane = "com.apple.preference.security?Privacy_Automation"
        case .filesAndFolders: pane = "com.apple.preference.security?Privacy_FilesAndFolders"
        case .fullDiskAccess: pane = "com.apple.preference.security?Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    var requiresSystemSettings: Bool {
        switch self {
        case .automation, .filesAndFolders, .fullDiskAccess: true
        default: false
        }
    }

    var supportsAppDrop: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording, .fullDiskAccess: true
        default: false
        }
    }

    var hasBooleanPreflight: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording: true
        default: false
        }
    }

    var searchKeywords: String {
        "permission \(rawValue) \(settingsURL.absoluteString) privacy macOS terminal agent"
    }
}

nonisolated enum SettingsPermissionStatus: Equatable, Sendable {
    case notDetermined, denied, restricted, granted, requesting, manual, unavailable

    var title: String {
        switch self {
        case .notDetermined, .denied: String(localized: "Not granted")
        case .restricted: String(localized: "Restricted")
        case .granted: String(localized: "Granted")
        case .requesting: String(localized: "Requesting")
        case .manual: String(localized: "Managed in System Settings")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    var actionTitle: String {
        switch self {
        case .notDetermined: String(localized: "Allow")
        case .requesting: String(localized: "Requesting")
        case .unavailable: String(localized: "Retry")
        case .denied, .restricted, .granted, .manual: String(localized: "Open System Settings")
        }
    }
}
