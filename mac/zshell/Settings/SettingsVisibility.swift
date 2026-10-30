import AppKit
import Combine

/// The pane and its search entries must expose the same dependent controls.
struct SettingsVisibility {
    struct Recommendations: Equatable {
        var homebrewAvailable = false
        var hasMissingTools = false
        var hasUpdatableTools = false

        var installMissing: Bool { homebrewAvailable && hasMissingTools }
        var updateAll: Bool { homebrewAvailable && hasUpdatableTools }
    }

    // Only the existing pane updates this snapshot, so search never starts tool checks.
    @MainActor private static var recommendedTools = Recommendations()
    @MainActor static let recommendationsDidChange = PassthroughSubject<Void, Never>()

    var aiEnabled: Bool
    var quickTerminalEnabled: Bool
    var fontThicken: Bool
    var showPaneFocusRing: Bool
    var gitProxyEnabled: Bool
    var browserContentBlocking: Bool
    var terminalBackgroundOpacity: Double
    var reduceTransparency: Bool
    var automaticallyChecksForUpdates: Bool
    var allowsAutomaticUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var recommendations: Recommendations

    var terminalBackgroundBlur: Bool { terminalBackgroundOpacity < 1 && !reduceTransparency }
    var automaticUpdateDownloads: Bool { automaticallyChecksForUpdates && allowsAutomaticUpdates }
    var automaticUpdateInstallation: Bool { automaticUpdateDownloads && automaticallyDownloadsUpdates }

    @MainActor static func updateRecommendations(_ visibility: Recommendations) {
        guard recommendedTools != visibility else { return }
        recommendedTools = visibility
        recommendationsDidChange.send(())
    }

    @MainActor static var current: SettingsVisibility {
        let settings = AppSettings.shared
        let updater = Updater.shared
        return SettingsVisibility(
            aiEnabled: settings.aiEnabled,
            quickTerminalEnabled: settings.quickTerminalEnabled,
            fontThicken: settings.fontThicken,
            showPaneFocusRing: settings.showPaneFocusRing,
            gitProxyEnabled: settings.gitProxyEnabled,
            browserContentBlocking: settings.browserContentBlocking,
            terminalBackgroundOpacity: settings.terminalBackgroundOpacity,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates,
            automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
            recommendations: recommendedTools
        )
    }
}
