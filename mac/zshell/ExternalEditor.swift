//
//  ExternalEditor.swift
//  zshell
//

import AppKit

/// An app the file tree and session dashboard can use to open files and folders.
@MainActor
enum ExternalEditor: String, CaseIterable {
    case systemDefault = "default"
    case visualStudioCode = "vscode"
    case zed
    case cursor

    var title: String {
        switch self {
        case .systemDefault:
            String(
                localized: "System Default",
                comment: "External editor choice that follows the macOS default application."
            )
        case .visualStudioCode:
            "VS Code"
        case .zed:
            "Zed"
        case .cursor:
            "Cursor"
        }
    }

    var openTitle: String {
        switch self {
        case .systemDefault:
            String(localized: "Open in Default App")
        case .visualStudioCode, .zed, .cursor:
            String(localized: "Open in \(title)")
        }
    }

    var isAvailable: Bool {
        guard let bundleIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) != nil
    }

    static func availableCases(including selected: ExternalEditor) -> [ExternalEditor] {
        allCases.filter { $0 == selected || $0.isAvailable }
    }

    /// Resolves the persisted choice for tests and non-UI callers without
    /// duplicating AppSettings' fallback rule.
    static func persisted(_ rawValue: String?) -> ExternalEditor {
        rawValue.flatMap(Self.init(rawValue:)) ?? .systemDefault
    }

    func open(_ url: URL) {
        guard let bundleIdentifier else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private var bundleIdentifier: String? {
        switch self {
        case .systemDefault: nil
        case .visualStudioCode: "com.microsoft.VSCode"
        case .zed: "dev.zed.Zed"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        }
    }
}
